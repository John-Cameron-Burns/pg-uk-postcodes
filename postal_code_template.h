#ifndef POSTAL_CODE_TEMPLATE_H__
#define POSTAL_CODE_TEMPLATE_H__

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#include "postal_code.h"

// Templated ("generic") postal code formats: a country whose codes are just
// fixed-width groups of digits and letters can be onboarded with an SQL row
// instead of a C encoder.
//
//   N   a digit                    0-9
//   A   a letter                   A-Z
//   X   a digit or a letter        0-9 then A-Z
//   ' ' or '-'                     a literal separator, at a fixed position
//   [ ... ]                        one optional group, at the very end
//   CC                             (first, optionally followed by a separator) the
//                                  country's own ISO letters, as in "VG1110" or
//                                  "AZ 1000": optional on input, checked against the
//                                  country, never stored, never written back
//
// so US ZIP+4 is "NNNNN[-NNNN]", the Czech PSC "NNN NN", Poland "NN-NNN",
// the Netherlands "NNNN AA", Canada (without its letter exclusions) "ANA[ NAN]".
//
// A template is the same kind of thing as a compiled encoder and obeys the
// same rules, the important ones being:
//
//  - Text order == numeric order of the payload. The payload is the code read
//    as a mixed-radix number, most significant symbol first, symbols ordered
//    as ASCII (digits before letters), so a coarser value sorts before the
//    finer ones that extend it. An optional group costs no bit pattern of
//    its own: the payload is  head * (1 + tail_space) + (tail ? 1 + tail : 0),
//    so the head alone is the smallest member of its family, exactly as a US
//    ZIP5 sorts just before every ZIP+4 on it. Every payload below `total`
//    is valid and has exactly one spelling; the rest are invalid.
//  - The head alone is a valid value, and is the outcode (the incode is the
//    optional group). A template with no optional group has no outcode.
//  - It orders as text, so any prefix of the code is one contiguous range.
//
// Separators are canonical on output and optional on input; letters are
// accepted in either case.
//
// This file is Postgres-free, like postal_code_fmt.c, so it can be driven
// from a plain standalone build (test_postal_code_template.c). How a stored
// value finds its template -- by format tag, slot PC_FMT_TEMPLATE_FIRST..LAST,
// looked up in postal_code_templates -- is in postal_code_tpl.c.

#define PC_TPL_MAX_ITEMS 40

typedef struct {
   char     spec[PC_TPL_MAX_ITEMS + 3]; // as written, incl. brackets
   char     item[PC_TPL_MAX_ITEMS + 1]; // per position: 'N' 'A' 'X' or the literal; no brackets
   int      nitems;
   int      tail_at;                    // first position of the optional group; == nitems if none
   bool     has_tail;
   bool     cc_prefix;                  // spec began "CC": the country's letters may precede the code
   uint64_t head_space;                 // distinct head values
   uint64_t tail_space;                 // distinct tail values (0 if none)
   uint64_t mult;                       // 1 + tail_space if there is a tail, else 1
   uint64_t total;                      // payloads 0 .. total-1 are valid
} pc_template;

// Compiles spec. On failure writes the reason to err and returns false.
// The template must fit the 48-bit payload.
__attribute__((warn_unused_result))
bool pc_template_compile (const char *spec, pc_template *t, char *err, size_t errlen);

// Where the code proper starts in text that may begin with the country's own
// letters (cc, upper case) when t->cc_prefix: past "VG", "VG ", "VG-"; else text itself.
const char *pc_template_skip_cc (const pc_template *t, const char cc[2], const char *text);

// The hooks, same contract as pc_encoder's (postal_code_fmt.h).
__attribute__((warn_unused_result))
bool     pc_template_parse   (const pc_template *t, const char *text, uint64_t *out);
int      pc_template_render  (const pc_template *t, uint64_t payload, char *buf);   // excl. NUL; buf holds nitems+1
bool     pc_template_valid   (const pc_template *t, uint64_t payload);
__attribute__((warn_unused_result))
bool     pc_template_range   (const pc_template *t, const char *fragment, uint64_t *lo, uint64_t *hi, bool *unbounded);
uint64_t pc_template_outcode (const pc_template *t, uint64_t payload);              // only if t->has_tail

#endif
