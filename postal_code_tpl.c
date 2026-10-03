#include <postgres.h>
#include <executor/spi.h>
#include <utils/builtins.h>
#include <utils/inval.h>
#include <catalog/pg_type.h>

#include "postal_code_fmt.h"
#include "postal_code_tpl.h"

typedef struct {
   bool        valid;
   pc_template tpl;
} slot_cache;

static slot_cache cache[PC_FMT_TEMPLATE_LAST + 1];
static Oid        templates_relid = InvalidOid;     // the table the cache was read from
static bool       callback_registered = false;
static SPIPlanPtr slot_plan = NULL;

static void templates_changed (Datum arg, Oid relid) {
   if (relid != InvalidOid && relid != templates_relid) return;
   memset(cache, 0, sizeof cache);
}

bool pc_template_for_slot (int slot, pc_template *out) {
   if (slot < PC_FMT_TEMPLATE_FIRST || slot > PC_FMT_TEMPLATE_LAST) return false;

   if (!callback_registered) {
      CacheRegisterRelcacheCallback(templates_changed, (Datum) 0);
      callback_registered = true;
   }
   if (cache[slot].valid) { *out = cache[slot].tpl; return true; }

   if (SPI_connect() != SPI_OK_CONNECT)
      ereport(ERROR, (errmsg("postal_code: SPI_connect failed looking up template slot %d", slot)));

   if (!slot_plan) {
      Oid argtypes[1] = { INT4OID };
      SPIPlanPtr plan = SPI_prepare(
         "SELECT template, 'postal_code_templates'::regclass::oid FROM postal_code_templates WHERE slot = $1",
         1, argtypes);
      if (!plan)
         ereport(ERROR, (errmsg("postal_code: failed to prepare template lookup (SPI error %d)", SPI_result)));
      if (SPI_keepplan(plan) != 0)
         ereport(ERROR, (errmsg("postal_code: failed to save template lookup plan")));
      slot_plan = plan;
   }

   Datum values[1] = { Int32GetDatum(slot) };
   int rc = SPI_execute_plan(slot_plan, values, NULL, true, 1);
   if (rc != SPI_OK_SELECT)
      ereport(ERROR, (errmsg("postal_code: template lookup failed (SPI error %d)", rc)));

   bool found = false;
   if (SPI_processed > 0) {
      bool isnull;
      Datum d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
      Datum r = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 2, &isnull);
      char *spec = TextDatumGetCString(d);
      char err[128];
      pc_template t;
      if (!pc_template_compile(spec, &t, err, sizeof err))
         ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
                         errmsg("postal_code_templates slot %d holds an invalid template \"%s\": %s", slot, spec, err)));
      templates_relid = DatumGetObjectId(r);
      cache[slot].tpl = t;
      cache[slot].valid = true;
      *out = t;
      found = true;
   }

   SPI_finish();
   return found;
}
