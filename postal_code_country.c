#include <postgres.h>
#include <executor/spi.h>
#include <utils/builtins.h>
#include <catalog/pg_type.h>

#include "postal_code_country.h"

// Prepared once per backend, reused for the life of the backend.
// SPI_keepplan() moves it out of the transient SPI memory context
// so it survives SPI_finish(); Postgres itself still owns the plan
// cache invalidation if postal_code_country_formats' schema ever
// changes underneath it (DDL, not the row-level INSERT/UPDATE this
// table is meant for day to day).
static SPIPlanPtr country_format_plan = NULL;

char *pc_lookup_country_format (const char iso2[2]) {
   MemoryContext caller_context = CurrentMemoryContext;
   char cc[3] = { iso2[0], iso2[1], '\0' };
   char *result = NULL;

   if (SPI_connect() != SPI_OK_CONNECT)
      ereport(ERROR, (errmsg("postal_code: SPI_connect failed looking up country '%s'", cc)));

   if (!country_format_plan) {
      Oid argtypes[1] = { TEXTOID };
      SPIPlanPtr plan = SPI_prepare(
         "SELECT format_name FROM postal_code_country_formats WHERE iso2 = $1",
         1, argtypes);
      if (!plan)
         ereport(ERROR, (errmsg("postal_code: failed to prepare country-format lookup (SPI error %d)",
                                 SPI_result)));
      if (SPI_keepplan(plan) != 0)
         ereport(ERROR, (errmsg("postal_code: failed to save country-format lookup plan")));
      country_format_plan = plan;
   }

   Datum values[1] = { CStringGetTextDatum(cc) };
   int rc = SPI_execute_plan(country_format_plan, values, NULL, /* read_only */ true, 1);
   if (rc != SPI_OK_SELECT)
      ereport(ERROR, (errmsg("postal_code: country-format lookup failed (SPI error %d)", rc)));

   if (SPI_processed > 0) {
      bool isnull;
      Datum d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
      if (!isnull) {
         // Copy out into the CALLER's context before SPI_finish()
         // tears down the context this Datum's text data lives in.
         char *spi_str = TextDatumGetCString(d);
         result = MemoryContextStrdup(caller_context, spi_str);
      }
   }

   SPI_finish();
   return result;
}
