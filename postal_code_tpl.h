#ifndef POSTAL_CODE_TPL_H__
#define POSTAL_CODE_TPL_H__

#include <stdbool.h>

#include "postal_code_template.h"

// Finds the template that format tag `slot` (PC_FMT_TEMPLATE_FIRST ..
// PC_FMT_TEMPLATE_LAST) stands for, from the postal_code_templates SQL table.
// False if the table has no such slot. The result is copied into *out.
//
// A slot's template never changes once written (the table refuses UPDATE and
// DELETE: stored values can only be read with the template they were written
// under), so it is cached in the backend. The only way a cached entry goes
// wrong is a rolled-back CREATE of that slot, which sends a relcache
// invalidation like any other change to the table, and the callback registered
// here empties the cache on it.
//
// Like postal_code_country.c this is the only place that does SPI for
// templates; postal_code_template.c stays Postgres-free.
__attribute__((warn_unused_result))
bool pc_template_for_slot (int slot, pc_template *out);

#endif
