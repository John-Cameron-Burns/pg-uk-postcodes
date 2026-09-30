#ifndef POSTAL_CODE_COUNTRY_H__
#define POSTAL_CODE_COUNTRY_H__

// Looks up which format name (e.g. "US") the postal_code_country_formats
// SQL table currently assigns to iso2 (2 uppercase letters, not
// NUL-terminated). Returns a palloc'd, NUL-terminated cstring in the
// CURRENT memory context, or NULL if iso2 has no assignment at all --
// callers should distinguish "no such country" (NULL) from "assigned
// to a format this build doesn't have" (non-NULL, but
// pc_format_by_name() on it returns PC_FMT_UNKNOWN) for a useful
// error message; see postal_code.c's lookup_country().
//
// Deliberately separate from postal_code_fmt.c/pc_format_by_name():
// this file is the ONLY place in the postal_code_* sources that
// touches Postgres/SPI, so that everything else stays usable from a
// plain standalone build (test_postal_code.c).
__attribute__((warn_unused_result))
char *pc_lookup_country_format (const char iso2[2]);

#endif
