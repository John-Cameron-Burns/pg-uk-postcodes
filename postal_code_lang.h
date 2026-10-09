#ifndef POSTAL_CODE_LANG_H__
#define POSTAL_CODE_LANG_H__

#include "postal_code_pattern.h"

// Finds the pattern for a country's language `version` (1..51, from the postal_code_languages SQL table) and
// compiles it. NULL if the country has no such language. A language never changes once it exists (the table
// refuses UPDATE and DELETE: stored values can only be read with the language they were written under), so
// compiled patterns are kept in the backend. The only way a kept one goes wrong is a rolled-back CREATE of
// that version, which sends a relcache invalidation like any other change to the table, and the callback
// registered here empties the cache on it.
//
// The pointer is good until the next call that may do SPI; use it straight away and do not keep it.
//
// Like postal_code_country.c this is the only place that does SPI for languages; the engine
// (postal_code_pattern.c) stays Postgres-free.
const pc_pattern *pc_language_for (const char iso2[2], int version);

// The named parts of a value's format (its tag, as stored in the value): the language's own pattern, or for a
// compiled format the pattern in postal_code_format_parts. NULL if there are none. Same lifetime rule.
const pc_parts *pc_parts_for (const char iso2[2], int fmt);

#endif
