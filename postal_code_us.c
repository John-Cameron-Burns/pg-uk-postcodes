#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>

#include "postal_code_fmt.h"

// US ZIP5 + optional ZIP+4, packed into the low 31 of the 48
// payload bits.
//
//   30                14 13            0
//  +--------------------+--------------+
//  |      zip5:17        |   plus4:14   |
//  +--------------------+--------------+
//
// plus4 == 0 means "no +4 supplied": real add-on codes are always
// 0001-9999, so 0 is a safe, unused sentinel -- the same trick
// postcode.h's DISTRICT2 uses for its own optional sub-field.
// Because plus4 sits in the low bits, a bare ZIP5 (plus4 absent)
// sorts immediately before that same ZIP5 with any real +4,
// interleaving naturally rather than being grouped apart by a
// format-level split.

#define US_PLUS4_BITS 14
#define US_ZIP5_BITS  17

#define US_PLUS4_POS  0
#define US_ZIP5_POS   US_PLUS4_BITS

#define US_GET_PLUS4(p)   GET_BITS64(p, US_PLUS4_POS, US_PLUS4_BITS)
#define US_GET_ZIP5(p)    GET_BITS64(p, US_ZIP5_POS,  US_ZIP5_BITS)

#define US_SET_PLUS4(p,v) SET_BITS64(p, US_PLUS4_POS, US_PLUS4_BITS, v)
#define US_SET_ZIP5(p,v)  SET_BITS64(p, US_ZIP5_POS,  US_ZIP5_BITS, v)

#define US_MAX_TEXT_LEN 10 // "NNNNN-NNNN"

static inline bool is_digit (char c) { return c >= '0' && c <= '9'; }

// Partial support here is deliberately minimal: a 1-5 digit ZIP5
// prefix is accepted and the +4 is left unset. This is enough to
// round-trip a bare ZIP5 constant, but it is not the UK format's
// range_lower()/range_upper() half-open-range machinery -- there is
// no index-assisted partial-match support for US values yet.
static bool us_parse (const char *str, bool partial, uint64_t *out) {
   if (!str) return false;

   uint32_t zip5 = 0;
   int i = 0;
   for (; i < 5; i++) {
      if (!is_digit(str[i])) {
         if (partial && str[i] == '\0' && i > 0) break;
         return false;
      }
      zip5 = zip5 * 10 + (uint32_t) (str[i] - '0');
   }

   uint64_t res = 0;
   US_SET_ZIP5(res, zip5);

   if (str[i] == '\0') { *out = res; return true; } // ZIP5 only, no +4
   if (partial)        { *out = res; return true; } // ignore trailing +4 in a fragment

   if (str[i] != '-' && str[i] != ' ') return false;
   i++;

   uint32_t plus4 = 0;
   int j = 0;
   for (; j < 4; j++) {
      if (!is_digit(str[i + j])) return false;
      plus4 = plus4 * 10 + (uint32_t) (str[i + j] - '0');
   }
   if (str[i + j] != '\0') return false; // trailing garbage
   if (plus4 == 0) return false;         // 0000 isn't a real add-on code

   US_SET_PLUS4(res, plus4);
   *out = res;
   return true;
}

static int us_render (uint64_t payload, char *buf) {
   uint32_t zip5  = (uint32_t) US_GET_ZIP5(payload);
   uint32_t plus4 = (uint32_t) US_GET_PLUS4(payload);

   if (zip5 > 99999) return sprintf(buf, "?????");
   if (plus4 == 0)   return sprintf(buf, "%05u", zip5);
   if (plus4 <= 9999) return sprintf(buf, "%05u-%04u", zip5, plus4);
   return sprintf(buf, "%05u-????", zip5);
}

static bool us_valid (uint64_t payload) {
   uint64_t used_bits = US_ZIP5_POS + US_ZIP5_BITS; // 31
   if (GET_BITS64(payload, used_bits, PC_PAYLOAD_BITS - used_bits)) return false;
   return US_GET_ZIP5(payload) <= 99999 && US_GET_PLUS4(payload) <= 9999;
}

const pc_encoder pc_us_encoder = {
   .name         = "US",
   .max_text_len = US_MAX_TEXT_LEN,
   .parse        = us_parse,
   .render       = us_render,
   .valid        = us_valid,
};
