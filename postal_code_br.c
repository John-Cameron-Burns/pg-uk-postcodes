#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>

#include "postal_code_fmt.h"
#include "postal_code_range.h"

// Brazilian CEP: 5-digit base + optional 3-digit suffix, written
// "NNNNN-NNN" when the suffix is present (e.g. "01310-100"). Unlike
// US's ZIP+4, the suffix can't use a sentinel value to mean "absent":
// "000" is itself a common, real suffix (a generic/less-precise
// reference point within the base 5-digit area, not "no suffix" --
// confirmed live, it's the majority value in GEONAMES.world's own BR
// sample) -- so, same reasoning as postal_code_ca.c's optional LDU, a
// dedicated presence bit is used instead of a reserved value.
//
//   27         11 10           9          0
//  +------------+-------------+------------+
//  |  base:17   | has_suffix:1|  suffix:10  |
//  +------------+-------------+------------+
//
// 28 of the 48 payload bits used. Critically, base is the MOST
// significant field, has_suffix sits directly below it (gating
// suffix, the least significant), not above everything -- an
// earlier draft put has_suffix as the single most-significant bit,
// which made every base-only value sort before every suffixed value
// regardless of base (e.g. "08971" before "08970-999", when text
// order -- and any sane numeric order -- puts "08970-999" first).
// A real mixed-country ordering test caught the identical mistake in
// postal_code_ca.c's has_ldu placement; fixed the same way here.
// With base on top, it dominates comparison first as it should, and
// a bare 5-digit CEP still sorts immediately before every fully
// specified "NNNNN-NNN" sharing that same base -- same "coarser
// sorts before its own finer children" property as CA's FSA-only
// values and US's bare ZIP5.

#define BR_BASE_BITS       17
#define BR_HAS_SUFFIX_BITS  1
#define BR_SUFFIX_BITS     10

#define BR_SUFFIX_POS     0
#define BR_HAS_SUFFIX_POS (BR_SUFFIX_POS     + BR_SUFFIX_BITS)
#define BR_BASE_POS       (BR_HAS_SUFFIX_POS + BR_HAS_SUFFIX_BITS)

#define BR_USED_BITS (BR_BASE_POS + BR_BASE_BITS) // 28

#define BR_GET_BASE(p)       GET_BITS64(p, BR_BASE_POS,       BR_BASE_BITS)
#define BR_GET_SUFFIX(p)     GET_BITS64(p, BR_SUFFIX_POS,     BR_SUFFIX_BITS)
#define BR_GET_HAS_SUFFIX(p) GET_BITS64(p, BR_HAS_SUFFIX_POS, BR_HAS_SUFFIX_BITS)

#define BR_SET_BASE(p,v)       SET_BITS64(p, BR_BASE_POS,       BR_BASE_BITS,       v)
#define BR_SET_SUFFIX(p,v)     SET_BITS64(p, BR_SUFFIX_POS,     BR_SUFFIX_BITS,     v)
#define BR_SET_HAS_SUFFIX(p,v) SET_BITS64(p, BR_HAS_SUFFIX_POS, BR_HAS_SUFFIX_BITS, v)

#define BR_MAX_TEXT_LEN 9 // "NNNNN-NNN"

static inline bool is_digit (char c) { return c >= '0' && c <= '9'; }

// A complete (non-partial) value is either the bare 5-digit base or
// the full "NNNNN-NNN" -- both first-class, same relationship as
// CA's FSA-only vs. FSA+LDU. partial=true additionally accepts a
// 1-4 digit prefix of the base, same minimal best-effort fragment
// support postal_code_us.c/postal_code_ca.c already have.
static bool br_parse (const char *str, bool partial, uint64_t *out) {
   if (!str) return false;

   uint32_t base = 0;
   int i = 0;
   for (; i < 5; i++) {
      if (!is_digit(str[i])) {
         if (partial && str[i] == '\0' && i > 0) break;
         return false;
      }
      base = base * 10 + (uint32_t) (str[i] - '0');
   }

   uint64_t res = 0;
   BR_SET_BASE(res, base);

   if (str[i] == '\0') { *out = res; return true; } // base only
   if (partial)        { *out = res; return true; } // ignore trailing suffix in a fragment

   if (str[i] == '-') i++;               // "01310-100", and "01310100" as it is usually written

   uint32_t suffix = 0;
   int j = 0;
   for (; j < 3; j++) {
      if (!is_digit(str[i + j])) return false;
      suffix = suffix * 10 + (uint32_t) (str[i + j] - '0');
   }
   if (str[i + j] != '\0') return false; // trailing garbage

   BR_SET_SUFFIX(res, suffix);
   BR_SET_HAS_SUFFIX(res, 1);
   *out = res;
   return true;
}

static int br_render (uint64_t payload, char *buf) {
   uint32_t base = (uint32_t) BR_GET_BASE(payload);
   int n = (base > 99999) ? sprintf(buf, "?????") : sprintf(buf, "%05u", base);

   if (!BR_GET_HAS_SUFFIX(payload)) return n;

   uint32_t suffix = (uint32_t) BR_GET_SUFFIX(payload);
   n += (suffix > 999) ? sprintf(buf + n, "-???") : sprintf(buf + n, "-%03u", suffix);
   return n;
}

static bool br_valid (uint64_t payload) {
   if (GET_BITS64(payload, BR_USED_BITS, PC_PAYLOAD_BITS - BR_USED_BITS)) return false;
   if (BR_GET_BASE(payload) > 99999) return false;

   if (!BR_GET_HAS_SUFFIX(payload)) {
      // canonical: suffix bits must be exactly zero when absent, so
      // there's only one valid encoding of a given base-only value
      if (BR_GET_SUFFIX(payload)) return false;
      return true;
   }
   return BR_GET_SUFFIX(payload) <= 999;
}

// Fragment: 1-5 base digits, or a full base then 1-3 suffix digits. Same
// shape as the US: a base fragment covers the bare base AND all its suffixes
// (the bare value sorts first); a suffix fragment starts at its smallest
// suffix ("000" is real here) and ends at the next base when it is the last.
static bool br_range (const char *str, uint64_t *lo, uint64_t *hi, bool *unbounded) {
   if (!str) return false;
   int k = 0;
   uint32_t z = 0;
   while (k < 5 && is_digit(str[k])) z = z * 10 + (uint32_t) (str[k++] - '0');
   if (k == 0) return false;

   *unbounded = false;
   // "01310" and "01310-" (a full base and its hyphen) are the same fragment: the base and every suffix on it
   bool bare = str[k] == '\0' || (k == 5 && str[k] == '-' && str[k + 1] == '\0');
   if (bare) {
      uint32_t zl, zh;
      pc_digit_prefix_bounds(z, k, 5, &zl, &zh);
      *lo = (uint64_t) zl << BR_BASE_POS;
      if (zh > 99999) *unbounded = true;
      else            *hi = (uint64_t) zh << BR_BASE_POS;
      return true;
   }

   if (k != 5) return false;
   const char *p = str + k + (str[k] == '-' ? 1 : 0);
   int m = 0;
   uint32_t a = 0;
   while (m < 3 && is_digit(p[m])) a = a * 10 + (uint32_t) (p[m++] - '0');
   if (m == 0 || p[m] != '\0') return false;

   uint32_t al, ah;
   pc_digit_prefix_bounds(a, m, 3, &al, &ah);
   uint64_t base = (uint64_t) z << BR_BASE_POS;
   uint64_t with = base | ((uint64_t) 1 << BR_HAS_SUFFIX_POS);
   *lo = with | al;
   if (ah <= 999)       *hi = with | ah;
   else if (z < 99999)  *hi = (uint64_t) (z + 1) << BR_BASE_POS;
   else                 *unbounded = true;
   return true;
}

// Outcode: the 5-digit base, dropping the suffix.
static uint64_t br_outcode (uint64_t payload) {
   BR_SET_SUFFIX(payload, 0);
   BR_SET_HAS_SUFFIX(payload, 0);
   return payload;
}

const pc_encoder pc_br_encoder = {
   .name         = "BR",
   .max_text_len = BR_MAX_TEXT_LEN,
   .parse        = br_parse,
   .render       = br_render,
   .valid        = br_valid,
   .range        = br_range,
   .outcode      = br_outcode,
};
