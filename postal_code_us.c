#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>

#include "postal_code_fmt.h"
#include "postal_code_range.h"

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

   if (str[i] == '-' || str[i] == ' ') i++;   // the separator is optional: "902101234" is a ZIP+4 too

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

// Fragment: 1-5 ZIP digits, or a full ZIP5 then 1-4 add-on digits. A ZIP5
// fragment covers the bare ZIP5 AND every +4 under it (they interleave: the
// bare value sorts first), so 90210 is [90210, 90211). An add-on fragment
// starts at 0001, since 0000 is not a real add-on; when the add-on prefix
// is the last of its ZIP5 the range ends at the next ZIP5.
static bool us_range (const char *str, uint64_t *lo, uint64_t *hi, bool *unbounded) {
   if (!str) return false;
   int k = 0;
   uint32_t z = 0;
   while (k < 5 && is_digit(str[k])) z = z * 10 + (uint32_t) (str[k++] - '0');
   if (k == 0) return false;

   *unbounded = false;
   if (str[k] == '\0') {
      uint32_t zl, zh;
      pc_digit_prefix_bounds(z, k, 5, &zl, &zh);
      *lo = (uint64_t) zl << US_ZIP5_POS;
      if (zh > 99999) *unbounded = true;
      else            *hi = (uint64_t) zh << US_ZIP5_POS;
      return true;
   }

   if (k != 5) return false;
   const char *p = str + k + ((str[k] == '-' || str[k] == ' ') ? 1 : 0);
   int m = 0;
   uint32_t a = 0;
   while (m < 4 && is_digit(p[m])) a = a * 10 + (uint32_t) (p[m++] - '0');
   // m == 0 is "90210-": text that starts with the hyphen, so only the +4 codes, not the bare ZIP5 itself
   if (p[m] != '\0' || (m == 4 && a == 0)) return false;

   uint32_t al, ah;
   pc_digit_prefix_bounds(a, m, 4, &al, &ah);
   if (al == 0) al = 1;
   *lo = ((uint64_t) z << US_ZIP5_POS) | al;
   if (ah <= 9999)      *hi = ((uint64_t) z << US_ZIP5_POS) | ah;
   else if (z < 99999)  *hi = (uint64_t) (z + 1) << US_ZIP5_POS;
   else                 *unbounded = true;
   return true;
}

// Outcode: the ZIP5, dropping the +4.
static uint64_t us_outcode (uint64_t payload) {
   US_SET_PLUS4(payload, 0);
   return payload;
}

const pc_encoder pc_us_encoder = {
   .name         = "US",
   .max_text_len = US_MAX_TEXT_LEN,
   .parse        = us_parse,
   .render       = us_render,
   .valid        = us_valid,
   .range        = us_range,
   .outcode      = us_outcode,
};
