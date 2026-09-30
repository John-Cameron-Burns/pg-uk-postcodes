#ifndef POSTAL_CODE_FMT_H__
#define POSTAL_CODE_FMT_H__

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#include "postal_code.h"

// One tag per *encoding scheme*, not per country: two countries
// that happen to share an identical payload layout would share a
// tag (none do yet, but nothing here assumes otherwise).
//
// Format is stored alongside country rather than derived from it,
// because a country can change its postal system over time --
// existing rows written under a country's old format must go on
// decoding correctly under that old format after the country
// adopts a new one, which a derived-from-country lookup couldn't
// do.
//
// PC_FMT_* values are part of the on-disk/wire format: append-only,
// same rule as areas.h's array. Only append a new tag when its
// encoder actually exists -- unlike areas.h, there's no reason to
// pre-reserve a number for a format that isn't implemented yet.
// PC_FMT_UNKNOWN(0) marks a value that hasn't been assigned a real
// format -- never a valid stored postcode.

typedef enum {
   PC_FMT_UNKNOWN = 0,
   PC_FMT_US      = 1,  // ZIP5 + optional ZIP+4
   PC_FMT_CA      = 2,  // ANA NAN, e.g. K1A 0B1
   PC_FMT_FR      = 3,  // 5 digits
   PC_FMT_BR      = 4,  // 5-digit base + optional 3-digit suffix (CEP)
   PC_FMT_CZ      = 5,  // 5 digits, "NNN NN"
   PC_FMT_LU      = 6,  // "L-" + 4 digits
   PC_FMT_MAX
} pc_format;

// Implemented once per format (postal_code_us.c, postal_code_ca.c,
// ...), each exposing one `const pc_encoder` instance, and wired
// into pc_formats[] in postal_code_fmt.c. Adding a country whose
// format already exists (e.g. a second ZIP5+4-style country) needs
// no new encoder and no rebuild -- just a row in the SQL
// postal_code_country_formats table (see add_country_format() in
// the extension's SQL, and postal_code_country.c for the lookup);
// only a genuinely new format needs new C code here.
//
// parse/render/valid all operate on just the 48-bit payload, not
// the full postal_code: country/format packing and unpacking is
// handled once, outside any individual encoder, so an encoder never
// needs to know its own format tag or where its payload sits within
// the wider 64-bit value.

typedef struct {
   const char *name;         // e.g. "US", "CA" -- diagnostics only
   size_t      max_text_len; // longest rendered form, excl. NUL

   // Success/failure comes back via the return value, not via the
   // written payload: an all-zero payload is a legitimate value in
   // more than one format (e.g. US "00000" with no +4, or CA
   // "A0A 0A0"), so it can't double as a "parse failed" sentinel
   // the way postcode.h's 1-indexed AREA field lets `0` do that job
   // for the UK type. *out is left untouched on failure.
   __attribute__((warn_unused_result))
   bool (*parse) (const char *text, bool partial, uint64_t *out);

   // buf must hold at least max_text_len+1 bytes. An unrenderable
   // field prints '?' rather than aborting (same convention as
   // postcode_render()); return value is the number of characters
   // written, excl. NUL.
   int      (*render) (uint64_t payload, char *buf);

   __attribute__((warn_unused_result))
   bool     (*valid)  (uint64_t payload);
} pc_encoder;

// Array of pointers, not values: a pc_encoder can only be wired in
// here by address (&pc_us_encoder, ...), since copying an extern
// const struct's value isn't a constant expression C allows in a
// static initializer. An unimplemented slot (PC_FMT_UNKNOWN, or any
// future gap) is NULL; check before calling through it.
extern const pc_encoder * const pc_formats[PC_FMT_MAX];

// Pure lookup by a format's registered name (pc_encoder.name, e.g.
// "US", "CA") -- linear scan, same convention as areas.h's own area
// lookup ("won't get large enough to need better than that any time
// soon"). This is the ONLY piece of country->format resolution that
// lives here: which country currently maps to which format name is
// no longer compiled in (see postal_code_country.c) -- this file
// stays free of any Postgres/SPI dependency, on purpose, so it's
// still usable from a plain standalone build (test_postal_code.c).
__attribute__((warn_unused_result))
pc_format pc_format_by_name (const char *name);

#endif
