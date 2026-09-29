#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>

#include "postal_code_fmt.h"

// French postal code: always exactly 5 digits (e.g. 75001), no
// separator, no optional sub-field -- unlike US/CA there's no
// recognised "coarser" standalone precision level; French addresses
// are always written with the full 5 digits.
//
// Real-world data note: GEONAMES.world's own FR rows are ~28%
// contaminated with trailing address-routing annotations appended
// after the 5 digits with a space -- "78078 CITYSSIMO" (a parcel
// locker brand), "75054 CEDEX 01" (a French business/PO-box mail
// routing suffix) and similar. That's not a genuine postal code
// variant, it's routing/service metadata that leaked into GeoNames'
// postal_code column for this country -- parse() rejects it as
// trailing garbage, same as it would reject any other unrecognised
// suffix, rather than silently swallowing or truncating it. Strip
// it upstream (before calling postal_code()/::postal_code) if
// importing from a source with this same contamination.
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
   if (str[i] != '\0') return false; // trailing garbage (incl. CEDEX/CITYSSIMO-style suffixes)

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
