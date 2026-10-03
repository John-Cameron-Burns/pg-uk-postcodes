#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>

#include "postal_code_fmt.h"
#include "postal_code_range.h"

// Canadian postal code, format ANA NAN (e.g. K1A 0B1): forward
// sortation area (FSA, first 3 chars) then local delivery unit
// (LDU, last 3 chars). D, F, I, O, Q and U never appear in any
// letter position (OCR confusability); W and Z additionally never
// appear as the first letter (reserved for future expansion).
//
// The LDU is genuinely optional, not just a formatting nicety: real
// data (GeoNames' worldwide postal code table, in particular --
// see project notes) is overwhelmingly FSA-only for Canada -- a
// bare "T0A" is a complete, valid postal code in its own right for
// large rural regions, not a truncated fragment of a longer one.
// So, same reasoning as postal_code_us.c's optional +4, except that
// here a dedicated presence bit is used rather than a sentinel
// value: unlike +4 (where 0000 is never real, freeing 0 to mean
// "absent"), every LDU digit/letter combination the 3-letter/3-digit
// space allows is potentially a real LDU, so there's no spare value
// within those fields themselves to repurpose as a sentinel.
//
// Letters are stored as their raw alphabet position (A=0..Z=25,
// same convention postcode.h's own WALK fields use), not as a rank
// within the reduced alphabet -- validity is a separate check
// (ca_letter_ok below), same relationship postcode.h has between a
// stored AREA/WALK value and its own valid_*() checks.
//
//   27      23 22     19 18     14 13         12      9 8       4 3      0
//  +----------+----------+----------+-----------+----------+----------+--------+
//  | letter1:5| digit1:4 | letter2:5| has_ldu:1 | digit2:4 | letter3:5| digit3:4|
//  +----------+----------+----------+-----------+----------+----------+--------+
//
// 28 of the 48 payload bits used. Field order (most-significant to
// least) matches both reading order and FSA-before-LDU geographic
// coarseness, the same left-to-right/coarse-to-fine convention
// postcode.h uses for AREA down to WALK2. Critically, has_ldu sits
// *below* the whole FSA (letter1/digit1/letter2) and *above* the LDU
// fields it gates -- not above everything -- so FSA comparison always
// dominates first (a real earlier draft got this backwards, putting
// has_ldu as the single most-significant bit: that made every
// FSA-only value sort before every full value regardless of FSA,
// e.g. "T0A" before "K1A 0B1", which a real mixed-country ordering
// test caught immediately). With has_ldu correctly placed here, a bare
// "T0A" (has_ldu=0, LDU bits canonically zero) sorts immediately
// before every fully-specified "T0A ..." sharing its own FSA, and
// FSAs themselves still sort alphabetically against each other
// regardless of which ones happen to have an LDU -- the same
// "coarser sorts before its own finer children" property
// postcode.h's own district-only fragments and postal_code_us.c's
// bare ZIP5 both rely on.

#define CA_DIGIT3_BITS  4
#define CA_LETTER3_BITS 5
#define CA_DIGIT2_BITS  4
#define CA_HAS_LDU_BITS 1
#define CA_LETTER2_BITS 5
#define CA_DIGIT1_BITS  4
#define CA_LETTER1_BITS 5

#define CA_DIGIT3_POS  0
#define CA_LETTER3_POS (CA_DIGIT3_POS  + CA_DIGIT3_BITS)
#define CA_DIGIT2_POS  (CA_LETTER3_POS + CA_LETTER3_BITS)
#define CA_HAS_LDU_POS (CA_DIGIT2_POS  + CA_DIGIT2_BITS)
#define CA_LETTER2_POS (CA_HAS_LDU_POS + CA_HAS_LDU_BITS)
#define CA_DIGIT1_POS  (CA_LETTER2_POS + CA_LETTER2_BITS)
#define CA_LETTER1_POS (CA_DIGIT1_POS  + CA_DIGIT1_BITS)

#define CA_USED_BITS   (CA_LETTER1_POS + CA_LETTER1_BITS) // 28

#define CA_GET_DIGIT3(p)   GET_BITS64(p, CA_DIGIT3_POS,  CA_DIGIT3_BITS)
#define CA_GET_LETTER3(p)  GET_BITS64(p, CA_LETTER3_POS, CA_LETTER3_BITS)
#define CA_GET_DIGIT2(p)   GET_BITS64(p, CA_DIGIT2_POS,  CA_DIGIT2_BITS)
#define CA_GET_LETTER2(p)  GET_BITS64(p, CA_LETTER2_POS, CA_LETTER2_BITS)
#define CA_GET_DIGIT1(p)   GET_BITS64(p, CA_DIGIT1_POS,  CA_DIGIT1_BITS)
#define CA_GET_LETTER1(p)  GET_BITS64(p, CA_LETTER1_POS, CA_LETTER1_BITS)
#define CA_GET_HAS_LDU(p)  GET_BITS64(p, CA_HAS_LDU_POS, CA_HAS_LDU_BITS)

#define CA_SET_DIGIT3(p,v)  SET_BITS64(p, CA_DIGIT3_POS,  CA_DIGIT3_BITS,  v)
#define CA_SET_LETTER3(p,v) SET_BITS64(p, CA_LETTER3_POS, CA_LETTER3_BITS, v)
#define CA_SET_DIGIT2(p,v)  SET_BITS64(p, CA_DIGIT2_POS,  CA_DIGIT2_BITS,  v)
#define CA_SET_LETTER2(p,v) SET_BITS64(p, CA_LETTER2_POS, CA_LETTER2_BITS, v)
#define CA_SET_DIGIT1(p,v)  SET_BITS64(p, CA_DIGIT1_POS,  CA_DIGIT1_BITS,  v)
#define CA_SET_LETTER1(p,v) SET_BITS64(p, CA_LETTER1_POS, CA_LETTER1_BITS, v)
#define CA_SET_HAS_LDU(p,v) SET_BITS64(p, CA_HAS_LDU_POS, CA_HAS_LDU_BITS, v)

#define CA_MAX_TEXT_LEN 7 // "ANA NAN" (FSA-only "ANA" is shorter, buffer sizes for the longer one)

// D F I O Q U, by alphabet position (A=0)
#define CA_EXCLUDE_GENERAL \
   ((1u << 3) | (1u << 5) | (1u << 8) | (1u << 14) | (1u << 16) | (1u << 20))
// + W Z, first letter only
#define CA_EXCLUDE_FIRST (CA_EXCLUDE_GENERAL | (1u << 22) | (1u << 25))

static inline bool ca_letter_ok (uint64_t v, uint32_t exclude_mask) {
   return v < 26 && !(exclude_mask & (1u << v));
}

static inline bool is_digit (char c) { return c >= '0' && c <= '9'; }
static inline bool is_alpha (char c) { return c >= 'A' && c <= 'Z'; }

// A complete (non-partial) value must be exactly 3 characters (FSA
// only) or exactly 6 (FSA+LDU) -- nothing in between is a real
// postal code, just an incomplete fragment of one.
//
// Partial support beyond that is minimal, same caveat as
// postal_code_us.c: a 1- or 2-character prefix is accepted for a
// best-effort fragment match. Fine for round-tripping a full value;
// not yet a basis for indexed partial-match queries.
static bool ca_parse (const char *str, bool partial, uint64_t *out) {
   if (!str) return false;

   char c[6];
   int got = 0;
   const char *s = str;

   for (int pos = 0; pos < 6; pos++) {
      while (*s == ' ') s++;
      if (*s == '\0') break;
      char ch = *s;
      if (ch >= 'a' && ch <= 'z') ch = (char) (ch - 32);

      bool want_letter = (pos == 0 || pos == 2 || pos == 4);
      if (want_letter ? !is_alpha(ch) : !is_digit(ch)) return false;

      c[pos] = ch;
      got = pos + 1;
      s++;
   }
   while (*s == ' ') s++;
   if (*s != '\0') return false; // trailing garbage
   if (got == 0) return false;
   if (!partial && got != 3 && got != 6) return false; // FSA-only or full, nothing else

   bool has_ldu = got > 3;
   uint64_t res = 0;
   if (got > 0) CA_SET_LETTER1(res, (uint64_t) (c[0] - 'A'));
   if (got > 1) CA_SET_DIGIT1(res,  (uint64_t) (c[1] - '0'));
   if (got > 2) CA_SET_LETTER2(res, (uint64_t) (c[2] - 'A'));
   if (has_ldu) {
      CA_SET_HAS_LDU(res, 1);
      if (got > 3) CA_SET_DIGIT2(res,  (uint64_t) (c[3] - '0'));
      if (got > 4) CA_SET_LETTER3(res, (uint64_t) (c[4] - 'A'));
      if (got > 5) CA_SET_DIGIT3(res,  (uint64_t) (c[5] - '0'));
   }

   if (!partial) {
      if (!ca_letter_ok(CA_GET_LETTER1(res), CA_EXCLUDE_FIRST))   return false;
      if (got > 2 && !ca_letter_ok(CA_GET_LETTER2(res), CA_EXCLUDE_GENERAL)) return false;
      if (has_ldu && !ca_letter_ok(CA_GET_LETTER3(res), CA_EXCLUDE_GENERAL)) return false;
   }
   *out = res;
   return true;
}

static int ca_render (uint64_t payload, char *buf) {
   uint64_t l1 = CA_GET_LETTER1(payload), d1 = CA_GET_DIGIT1(payload), l2 = CA_GET_LETTER2(payload);

   char cl1 = ca_letter_ok(l1, CA_EXCLUDE_FIRST)   ? (char) ('A' + l1) : '?';
   char cd1 = d1 <= 9                              ? (char) ('0' + d1) : '?';
   char cl2 = ca_letter_ok(l2, CA_EXCLUDE_GENERAL) ? (char) ('A' + l2) : '?';

   if (!CA_GET_HAS_LDU(payload))
      return sprintf(buf, "%c%c%c", cl1, cd1, cl2);

   uint64_t d2 = CA_GET_DIGIT2(payload), l3 = CA_GET_LETTER3(payload), d3 = CA_GET_DIGIT3(payload);
   char cd2 = d2 <= 9                              ? (char) ('0' + d2) : '?';
   char cl3 = ca_letter_ok(l3, CA_EXCLUDE_GENERAL) ? (char) ('A' + l3) : '?';
   char cd3 = d3 <= 9                              ? (char) ('0' + d3) : '?';

   return sprintf(buf, "%c%c%c %c%c%c", cl1, cd1, cl2, cd2, cl3, cd3);
}

static bool ca_valid (uint64_t payload) {
   if (GET_BITS64(payload, CA_USED_BITS, PC_PAYLOAD_BITS - CA_USED_BITS)) return false;
   if (!ca_letter_ok(CA_GET_LETTER1(payload), CA_EXCLUDE_FIRST))   return false;
   if (!ca_letter_ok(CA_GET_LETTER2(payload), CA_EXCLUDE_GENERAL)) return false;
   if (CA_GET_DIGIT1(payload) > 9) return false;

   if (!CA_GET_HAS_LDU(payload)) {
      // Canonical: LDU bits must be exactly zero when absent, so
      // there's only ever one valid encoding of a given FSA-only
      // value -- otherwise two different bit patterns could render
      // identically, which would break equality/index correctness.
      if (CA_GET_DIGIT2(payload) || CA_GET_LETTER3(payload) || CA_GET_DIGIT3(payload)) return false;
      return true;
   }
   if (!ca_letter_ok(CA_GET_LETTER3(payload), CA_EXCLUDE_GENERAL)) return false;
   if (CA_GET_DIGIT2(payload) > 9) return false;
   if (CA_GET_DIGIT3(payload) > 9) return false;
   return true;
}

// ---- fragment ranges -------------------------------------------------
// A fragment is 1-6 characters of the usual pattern (letter, digit, letter,
// digit, letter, digit; spaces ignored). Levels, most significant first:
//   0 letter1  1 digit1  2 letter2  |  3 digit2  4 letter3  5 digit3
// with has_ldu set exactly when the value is at level 3 or deeper. The range
// of a fragment ending at level L is [fragment padded with the smallest
// symbols, successor at level L): the successor increments level L to its
// next ALLOWED symbol (skipping D/F/I/O/Q/U, and W/Z for letter1), resets
// everything below it, and on overflow carries to level L-1. Carrying out of
// the LDU (3 -> 2) lands on the next FSA's outcode, since the presence bit
// goes back to 0; carrying out of level 0 means there is no successor.

static uint32_t ca_excl (int level) { return level == 0 ? CA_EXCLUDE_FIRST : CA_EXCLUDE_GENERAL; }

static bool ca_next_symbol (int v[6], int level) {
   if (level % 2 == 1) {                        // digit levels: 1, 3, 5
      if (v[level] >= 9) return false;
      v[level]++;
      return true;
   }
   for (int a = v[level] + 1; a < 26; a++)
      if (ca_letter_ok((uint64_t) a, ca_excl(level))) { v[level] = a; return true; }
   return false;
}

static uint64_t ca_pack (const int v[6], bool has_ldu) {
   uint64_t p = 0;
   CA_SET_LETTER1(p, (uint64_t) v[0]);
   CA_SET_DIGIT1(p,  (uint64_t) v[1]);
   CA_SET_LETTER2(p, (uint64_t) v[2]);
   if (has_ldu) {
      CA_SET_HAS_LDU(p, 1);
      CA_SET_DIGIT2(p,  (uint64_t) v[3]);
      CA_SET_LETTER3(p, (uint64_t) v[4]);
      CA_SET_DIGIT3(p,  (uint64_t) v[5]);
   }
   return p;
}

static bool ca_range (const char *str, uint64_t *lo, uint64_t *hi, bool *unbounded) {
   if (!str) return false;

   int v[6] = { 0, 0, 0, 0, 0, 0 };
   int depth = 0;
   const char *s = str;
   for (; depth < 6; depth++) {
      while (*s == ' ') s++;
      if (*s == '\0') break;
      char ch = *s;
      if (ch >= 'a' && ch <= 'z') ch = (char) (ch - 32);
      if (depth % 2 == 0) {                      // letter levels: 0, 2, 4
         if (!is_alpha(ch) || !ca_letter_ok((uint64_t) (ch - 'A'), ca_excl(depth))) return false;
         v[depth] = ch - 'A';
      } else {
         if (!is_digit(ch)) return false;
         v[depth] = ch - '0';
      }
      s++;
   }
   while (*s == ' ') s++;
   if (depth == 0 || *s != '\0') return false;

   *lo = ca_pack(v, depth >= 4);

   int w[6];
   for (int i = 0; i < 6; i++) w[i] = v[i];
   for (int level = depth - 1; ; level--) {
      if (ca_next_symbol(w, level)) {
         for (int j = level + 1; j < 6; j++) w[j] = 0;
         *hi = ca_pack(w, level >= 3);
         *unbounded = false;
         return true;
      }
      if (level == 0) { *unbounded = true; return true; }
   }
}

// Outcode: the FSA, dropping the LDU (and with it the presence bit, which
// is how a bare FSA is represented).
static uint64_t ca_outcode (uint64_t payload) {
   CA_SET_HAS_LDU(payload, 0);
   CA_SET_DIGIT2(payload, 0);
   CA_SET_LETTER3(payload, 0);
   CA_SET_DIGIT3(payload, 0);
   return payload;
}

const pc_encoder pc_ca_encoder = {
   .name         = "CA",
   .max_text_len = CA_MAX_TEXT_LEN,
   .parse        = ca_parse,
   .render       = ca_render,
   .valid        = ca_valid,
   .range        = ca_range,
   .outcode      = ca_outcode,
};
