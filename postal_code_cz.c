#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>

#include "postal_code_fmt.h"

// Czech postal code (PSC): 5 digits, conventionally rendered with a
// space after the third digit (e.g. "110 00"), tolerant of the space
// being omitted on input -- real GEONAMES.world data is uniformly
// "NNN NN" (all 15,507 CZ rows checked, none shorter/longer, none
// missing the space), but there's no reason to require it on input.
// Like France, always the full 5 digits -- no recognised shorter
// standalone precision level.
//
//   16           0
//  +--------------+
//  |   value:17   |
//  +--------------+
//
// 17 of the 48 payload bits used.

#define CZ_VALUE_BITS 17
#define CZ_VALUE_POS  0

#define CZ_GET_VALUE(p)   GET_BITS64(p, CZ_VALUE_POS, CZ_VALUE_BITS)
#define CZ_SET_VALUE(p,v) SET_BITS64(p, CZ_VALUE_POS, CZ_VALUE_BITS, v)

#define CZ_MAX_TEXT_LEN 6 // "NNN NN"

static inline bool is_digit (char c) { return c >= '0' && c <= '9'; }

static bool cz_parse (const char *str, bool partial, uint64_t *out) {
   if (!str) return false;

   uint32_t value = 0;
   int got = 0;
   const char *s = str;
   for (; got < 5; got++) {
      if (got == 3 && *s == ' ') s++; // optional space after the 3rd digit
      if (!is_digit(*s)) {
         if (partial && *s == '\0' && got > 0) break;
         return false;
      }
      value = value * 10 + (uint32_t) (*s - '0');
      s++;
   }
   if (*s != '\0') return false; // trailing garbage

   uint64_t res = 0;
   CZ_SET_VALUE(res, value);
   *out = res;
   return true;
}

static int cz_render (uint64_t payload, char *buf) {
   uint32_t value = (uint32_t) CZ_GET_VALUE(payload);
   if (value > 99999) return sprintf(buf, "?????");
   return sprintf(buf, "%03u %02u", value / 100, value % 100);
}

static bool cz_valid (uint64_t payload) {
   if (GET_BITS64(payload, CZ_VALUE_BITS, PC_PAYLOAD_BITS - CZ_VALUE_BITS)) return false;
   return CZ_GET_VALUE(payload) <= 99999;
}

const pc_encoder pc_cz_encoder = {
   .name         = "CZ",
   .max_text_len = CZ_MAX_TEXT_LEN,
   .parse        = cz_parse,
   .render       = cz_render,
   .valid        = cz_valid,
};
