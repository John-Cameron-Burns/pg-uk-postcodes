#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>

#include "postal_code_fmt.h"

// French postal code: always exactly 5 digits (e.g. 75001), no
// separator, no optional sub-field -- unlike US/CA there's no
// recognised "coarser" standalone precision level; French addresses
// are always written with the full 5 digits, so a prefix is not a
// postcode here.
//
// CEDEX is accepted and normalised away. "75054 CEDEX 01" is how
// organisations with their own CEDEX code are addressed: the 5 digits
// are a real, distinct postcode (in GeoNames' FR rows, 14,349 of the
// 14,353 rows that carry a suffix have a 5-digit part that appears
// nowhere else as a bare code -- so rejecting them would make ~28% of
// France's real postcodes unstorable), and "CEDEX [n]" is distribution
// routing for the address, not part of the code. It is stripped on
// input, the same kind of normalisation as the CZ space or the LU "L-";
// the stored value and its text form are just "75054". Nothing is lost
// in the data checked: every such row has a different 5-digit part.
//
// The accepted grammar is deliberately exactly NNNNN, NNNNN CEDEX, or
// NNNNN CEDEX n (n one or two digits, which is all the data contains) --
// NOT "ignore whatever follows the digits", so "75001 foo" is still an
// error. The few other oddities GeoNames carries ("SP 07" and "AIR",
// military mail designators; "CITYSSIMO", a parcel-locker brand: 21 of
// 51,611 rows) are rejected here; to_postal_code() returns NULL for them
// instead of raising, for loading feeds that contain them.
//
//   16           0
//  +--------------+
//  |   value:17   |
//  +--------------+
//
// 17 of the 48 payload bits used.

#define FR_VALUE_BITS 17
#define FR_VALUE_POS  0

#define FR_GET_VALUE(p)   GET_BITS64(p, FR_VALUE_POS, FR_VALUE_BITS)
#define FR_SET_VALUE(p,v) SET_BITS64(p, FR_VALUE_POS, FR_VALUE_BITS, v)

#define FR_MAX_TEXT_LEN 5

static inline bool is_digit (char c) { return c >= '0' && c <= '9'; }

static inline bool ci_eq (char a, char b) { return (a | 0x20) == (b | 0x20); }

static bool fr_parse (const char *str, bool partial, uint64_t *out) {
   if (!str) return false;

   uint32_t value = 0;
   int i = 0;
   for (; i < 5; i++) {
      if (!is_digit(str[i])) {
         if (partial && str[i] == '\0' && i > 0) break;
         return false;
      }
      value = value * 10 + (uint32_t) (str[i] - '0');
   }

   if (i == 5 && str[i] != '\0') {
      // only a CEDEX designation may follow the 5 digits: " CEDEX" and
      // then optionally " n" / " nn"; trailing spaces are tolerated
      const char *s = str + i;
      if (*s != ' ') return false;
      while (*s == ' ') s++;
      for (const char *w = "CEDEX"; *w; w++, s++)
         if (!ci_eq(*s, *w)) return false;
      if (*s == ' ') {
         while (*s == ' ') s++;
         if (is_digit(*s)) {
            s++;
            if (is_digit(*s)) s++;
         }
      }
      while (*s == ' ') s++;
      if (*s != '\0') return false;
   }

   uint64_t res = 0;
   FR_SET_VALUE(res, value);
   *out = res;
   return true;
}

static int fr_render (uint64_t payload, char *buf) {
   uint32_t value = (uint32_t) FR_GET_VALUE(payload);
   if (value > 99999) return sprintf(buf, "?????");
   return sprintf(buf, "%05u", value);
}

static bool fr_valid (uint64_t payload) {
   if (GET_BITS64(payload, FR_VALUE_BITS, PC_PAYLOAD_BITS - FR_VALUE_BITS)) return false;
   return FR_GET_VALUE(payload) <= 99999;
}

const pc_encoder pc_fr_encoder = {
   .name         = "FR",
   .max_text_len = FR_MAX_TEXT_LEN,
   .parse        = fr_parse,
   .render       = fr_render,
   .valid        = fr_valid,
};
