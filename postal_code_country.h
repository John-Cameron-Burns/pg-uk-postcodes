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
//
// *version is set to the country's current language (the highest version in
// postal_code_languages) when the assigned format is "pattern", else -1.
__attribute__((warn_unused_result))
char *pc_lookup_country_format (const char iso2[2], int *version);

// The schema the extension is installed in, quoted for use in SQL text. The
// SPI lookups name their tables with it rather than trusting search_path,
// which pg_dump and pg_restore (and any function with a locked-down
// search_path) set to nothing at all -- the type's own input and output
// functions run during a restore, before anything else is in place.
const char *pc_schema_prefix (void);

// ... and its OID.
Oid pc_extension_schema_oid (void);

#endif
