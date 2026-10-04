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

static MemoryContext langctx = NULL;           // everything compiled lives here; emptied on invalidation
static entry          cache[CACHE_SLOTS];
static int            ncached = 0;
static bool           stale = false;
static bool           callback_registered = false;
static SPIPlanPtr     lang_plan = NULL;

static void languages_changed (Datum arg, Oid relid) {
   stale = true;                                // emptied at the next lookup, never under a caller's feet
}

static void *ctx_alloc (size_t n) { return MemoryContextAlloc(langctx, n); }

const pc_pattern *pc_language_for (const char iso2[2], int version) {
   if (version < 1 || version > PC_FMT_LANG_LAST - PC_FMT_LANG_BASE) return NULL;

   if (!callback_registered) {
      CacheRegisterRelcacheCallback(languages_changed, (Datum) 0);
      callback_registered = true;
   }
   if (!langctx)
      langctx = AllocSetContextCreate(CacheMemoryContext, "postal_code languages", ALLOCSET_DEFAULT_SIZES);
   if (stale) {
      MemoryContextReset(langctx);
      ncached = 0;
      stale = false;
   }
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
      if (ncached == CACHE_SLOTS) { MemoryContextReset(langctx); ncached = 0; pat = pc_pattern_compile(regex, ctx_alloc, err, sizeof err); }
      cache[ncached].iso2[0] = iso2[0];
      cache[ncached].iso2[1] = iso2[1];
      cache[ncached].version = version;
      cache[ncached].pat = pat;
      ncached++;
   }

   SPI_finish();
   return pat;
}
