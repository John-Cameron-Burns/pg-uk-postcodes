#include <postgres.h>
#include <executor/spi.h>
#include <utils/builtins.h>
#include <utils/inval.h>
#include <utils/memutils.h>
#include <catalog/pg_type.h>

#include "postal_code_fmt.h"
#include "postal_code_country.h"
#include "postal_code_lang.h"

#define CACHE_SLOTS 256

typedef struct { char iso2[2]; int version; pc_pattern *pat; } entry;
typedef struct { char iso2[2]; int fmt; pc_parts *parts; } pentry;

static MemoryContext langctx = NULL;           // everything compiled lives here; emptied on invalidation
static entry          cache[CACHE_SLOTS];
static int            ncached = 0;
static pentry         pcache[CACHE_SLOTS];            // parts patterns, in the same memory context and emptied with it
static int            npcached = 0;
static bool           stale = false;
static bool           callback_registered = false;
static SPIPlanPtr     lang_plan = NULL;
static SPIPlanPtr     parts_plan = NULL;

static void languages_changed (Datum arg, Oid relid) {
   stale = true;                                // emptied at the next lookup, never under a caller's feet
}

static void *ctx_alloc (size_t n) { return MemoryContextAlloc(langctx, n); }

static void lang_begin (void) {
   if (!callback_registered) {
      CacheRegisterRelcacheCallback(languages_changed, (Datum) 0);
      callback_registered = true;
   }
   if (!langctx)
      langctx = AllocSetContextCreate(CacheMemoryContext, "postal_code languages", ALLOCSET_DEFAULT_SIZES);
   if (stale) {
      MemoryContextReset(langctx);
      ncached = 0;
      npcached = 0;
      stale = false;
   }
}

const pc_pattern *pc_language_for (const char iso2[2], int version) {
   if (version < 1 || version > PC_FMT_LANG_LAST - PC_FMT_LANG_BASE) return NULL;

   lang_begin();
   for (int i = 0; i < ncached; i++)
      if (cache[i].version == version && cache[i].iso2[0] == iso2[0] && cache[i].iso2[1] == iso2[1]) return cache[i].pat;

   char cc[3] = { iso2[0], iso2[1], '\0' };
   if (SPI_connect() != SPI_OK_CONNECT)
      ereport(ERROR, (errmsg("postal_code: SPI_connect failed looking up the language of %s", cc)));

   if (!lang_plan) {
      Oid argtypes[2] = { TEXTOID, INT4OID };
      SPIPlanPtr plan = SPI_prepare(
         psprintf("SELECT pattern FROM %spostal_code_languages WHERE iso2 = $1 AND version = $2", pc_schema_prefix()),
         2, argtypes);
      if (!plan)
         ereport(ERROR, (errmsg("postal_code: failed to prepare language lookup (SPI error %d)", SPI_result)));
      if (SPI_keepplan(plan) != 0)
         ereport(ERROR, (errmsg("postal_code: failed to save language lookup plan")));
      lang_plan = plan;
   }

   Datum values[2] = { CStringGetTextDatum(cc), Int32GetDatum(version) };
   int rc = SPI_execute_plan(lang_plan, values, NULL, true, 1);
   if (rc != SPI_OK_SELECT)
      ereport(ERROR, (errmsg("postal_code: language lookup failed (SPI error %d)", rc)));

   pc_pattern *pat = NULL;
   if (SPI_processed > 0) {
      bool isnull;
      Datum d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
      char *regex = TextDatumGetCString(d);
      char err[200];
      pat = pc_pattern_compile(regex, ctx_alloc, err, sizeof err);
      if (!pat)
         ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
                         errmsg("postal_code_languages holds an invalid pattern for %s version %d: %s", cc, version, err)));
      if (ncached == CACHE_SLOTS) { MemoryContextReset(langctx); ncached = 0; npcached = 0; pat = pc_pattern_compile(regex, ctx_alloc, err, sizeof err); }
      cache[ncached].iso2[0] = iso2[0];
      cache[ncached].iso2[1] = iso2[1];
      cache[ncached].version = version;
      cache[ncached].pat = pat;
      ncached++;
   }

   SPI_finish();
   return pat;
}

// The parts pattern for a value's format tag: a language's own pattern (its names are part of it), or, for a
// compiled format, the row in postal_code_format_parts. NULL if there is none.
const pc_parts *pc_parts_for (const char iso2[2], int fmt) {
   bool is_lang = fmt >= PC_FMT_LANG_FIRST && fmt <= PC_FMT_LANG_LAST;
   if (!is_lang && !(fmt > PC_FMT_UNKNOWN && fmt < PC_FMT_MAX && pc_formats[fmt])) return NULL;

   lang_begin();
   char key0 = is_lang ? iso2[0] : ' ', key1 = is_lang ? iso2[1] : ' ';   // a compiled format does not depend on the country
   for (int i = 0; i < npcached; i++)
      if (pcache[i].fmt == fmt && pcache[i].iso2[0] == key0 && pcache[i].iso2[1] == key1) return pcache[i].parts;

   if (SPI_connect() != SPI_OK_CONNECT)
      ereport(ERROR, (errmsg("postal_code: SPI_connect failed looking up the parts of format %d", fmt)));

   SPIPlanPtr *planp = is_lang ? &lang_plan : &parts_plan;
   if (!*planp) {
      Oid langtypes[2] = { TEXTOID, INT4OID };
      Oid fmttypes[1] = { TEXTOID };
      SPIPlanPtr plan = is_lang
         ? SPI_prepare(psprintf("SELECT pattern FROM %spostal_code_languages WHERE iso2 = $1 AND version = $2", pc_schema_prefix()), 2, langtypes)
         : SPI_prepare(psprintf("SELECT pattern FROM %spostal_code_format_parts WHERE format_name = $1", pc_schema_prefix()), 1, fmttypes);
      if (!plan)
         ereport(ERROR, (errmsg("postal_code: failed to prepare parts lookup (SPI error %d)", SPI_result)));
      if (SPI_keepplan(plan) != 0)
         ereport(ERROR, (errmsg("postal_code: failed to save parts lookup plan")));
      *planp = plan;
   }

   char cc[3] = { iso2[0], iso2[1], '\0' };
   Datum values[2];
   int rc;
   if (is_lang) {
      values[0] = CStringGetTextDatum(cc);
      values[1] = Int32GetDatum(fmt - PC_FMT_LANG_BASE);
      rc = SPI_execute_plan(*planp, values, NULL, true, 1);
   } else {
      values[0] = CStringGetTextDatum(pc_formats[fmt]->name);
      rc = SPI_execute_plan(*planp, values, NULL, true, 1);
   }
   if (rc != SPI_OK_SELECT)
      ereport(ERROR, (errmsg("postal_code: parts lookup failed (SPI error %d)", rc)));

   pc_parts *parts = NULL;
   if (SPI_processed > 0) {
      bool isnull;
      Datum d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
      char *regex = TextDatumGetCString(d);
      char err[200];
      parts = pc_parts_compile(regex, ctx_alloc, err, sizeof err);
      if (!parts)
         ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
                         errmsg("the parts pattern of postal_code format %d is invalid: %s", fmt, err)));
      if (npcached == CACHE_SLOTS) { MemoryContextReset(langctx); ncached = 0; npcached = 0; parts = pc_parts_compile(regex, ctx_alloc, err, sizeof err); }
      pcache[npcached].iso2[0] = key0;
      pcache[npcached].iso2[1] = key1;
      pcache[npcached].fmt = fmt;
      pcache[npcached].parts = parts;
      npcached++;
   }

   SPI_finish();
   return parts;
}
