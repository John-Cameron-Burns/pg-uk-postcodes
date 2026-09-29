#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>

#include "postal_code_fmt.h"

// Luxembourg postal code: "L-" followed by 4 digits, e.g. "L-1311".
// Unlike US/CA's own separators (which this repo's parser is merely
// tolerant of on input), the "L-" prefix is rendered as part of the
// canonical form here: it's genuinely how this is conventionally
// written in real Luxembourg addressing (the same convention several
// countries use for their own international mail prefix, e.g.
// Switzerland's "CH-"), and GEONAMES.world's real LU data is 100%
// this shape (all 4,519 rows checked) -- dropping it on output would
// make round-tripping real data look lossy, the way stripping any
// other genuinely-real character would. Input tolerates the prefix
// (either case) being entirely absent.
//
//   13         0
//  +------------+
//  |  value:14  |
//  +------------+
//
// 14 of the 48 payload bits used.

#define LU_VALUE_BITS 14
#define LU_VALUE_POS  0

#define LU_GET_VALUE(p)   GET_BITS64(p, LU_VALUE_POS, LU_VALUE_BITS)
#define LU_SET_VALUE(p,v) SET_BITS64(p, LU_VALUE_POS, LU_VALUE_BITS, v)

#define LU_MAX_TEXT_LEN 6 // "L-NNNN"

static inline bool is_digit (char c) { return c >= '0' && c <= '9'; }

static bool lu_parse (const char *str, bool partial, uint64_t *out) {
   if (!str) return false;

   const char *s = str;
   if ((s[0] == 'L' || s[0] == 'l') && s[1] == '-') s += 2;

   uint32_t value = 0;
   int i = 0;
   for (; i < 4; i++) {
      if (!is_digit(s[i])) {
         if (partial && s[i] == '\0' && i > 0) break;
         return false;
      }
      value = value * 10 + (uint32_t) (s[i] - '0');
   }
   if (s[i] != '\0') return false; // trailing garbage

   uint64_t res = 0;
   LU_SET_VALUE(res, value);
   *out = res;
   return true;
}

static int lu_render (uint64_t payload, char *buf) {
   uint32_t value = (uint32_t) LU_GET_VALUE(payload);
   if (value > 9999) return sprintf(buf, "L-????");
   return sprintf(buf, "L-%04u", value);
}

static bool lu_valid (uint64_t payload) {
   if (GET_BITS64(payload, LU_VALUE_BITS, PC_PAYLOAD_BITS - LU_VALUE_BITS)) return false;
   return LU_GET_VALUE(payload) <= 9999;
}

const pc_encoder pc_lu_encoder = {
   .name         = "LU",
   .max_text_len = LU_MAX_TEXT_LEN,
   .parse        = lu_parse,
   .render       = lu_render,
   .valid        = lu_valid,
};
