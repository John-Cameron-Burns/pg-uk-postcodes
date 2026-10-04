#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "postal_code_fmt.h"
#include "postal_code_range.h"

// Irish Eircode: a 3-character routing key (the outcode) and a
// 4-character unique identifier, written "A65 F4E2" (space optional on
// input). Every character is drawn from 25 symbols -- the digits and
// the 15 letters A C D E F H K N P R T V W X Y (chosen to avoid OCR
// confusion and accidental words). A routing key is a letter followed
// by two digits, with the single exception D6W.
//
// The routing key alone is a complete, valid value, not a fragment:
// all 139 of GeoNames' IE rows are bare routing keys. The unique
// identifier is optional, gated by a presence bit rather than a
// sentinel (any 4-symbol combination is a potentially real
// identifier, so no value is free to mean "absent").
//
// Symbols are stored as their index in IE_ALPHABET, which is in ASCII
// order (digits, then letters), so the packed integer compares exactly
// as the text does. 25 symbols fit in 5 bits.
//
//   35    31 30    26 25    21 20       19    15 14   10 9    5 4     0
//  +--------+--------+--------+---------+-------+-------+------+------+
//  | rk0:5  | rk1:5  | rk2:5  | has_uid | u0:5  | u1:5  | u2:5 | u3:5 |
//  +--------+--------+--------+---------+-------+-------+------+------+
//
// 36 of the 48 payload bits used. has_uid sits below the whole routing
// key and above the identifier it gates -- NOT above everything (see the
// ordering bug described in postal_code_ca.c) -- so routing keys compare
// first, and a bare key sorts immediately before every full code in it.

#define IE_ALPHABET "0123456789ACDEFHKNPRTVWXY"
#define IE_NSYM     25
#define IE_FIRST_LETTER 10 // index of 'A' in IE_ALPHABET

#define IE_SYM_BITS 5
#define IE_UID_POS  0                              // 4 symbols, 20 bits
#define IE_HAS_UID_POS 20
#define IE_RK_POS   21                             // 3 symbols, 15 bits
#define IE_USED_BITS 36

#define IE_MAX_TEXT_LEN 8 // "A65 F4E2"

// symbol -> index, or -1
static int ie_index (char c) {
   if (c >= 'a' && c <= 'z') c = (char) (c - 32);
   const char *p = c ? strchr(IE_ALPHABET, c) : NULL;
   return p ? (int) (p - IE_ALPHABET) : -1;
}

static inline unsigned ie_rk (uint64_t pl, int i) {   // i = 0..2, 0 most significant
   return (unsigned) GET_BITS64(pl, IE_RK_POS + (2 - i) * IE_SYM_BITS, IE_SYM_BITS);
}
static inline unsigned ie_uid (uint64_t pl, int i) {  // i = 0..3, 0 most significant
   return (unsigned) GET_BITS64(pl, IE_UID_POS + (3 - i) * IE_SYM_BITS, IE_SYM_BITS);
}

static bool ie_routing_key_ok (unsigned k0, unsigned k1, unsigned k2) {
   if (k0 >= IE_NSYM || k1 >= IE_NSYM || k2 >= IE_NSYM) return false;
   if (IE_ALPHABET[k0] == 'D' && k1 == 6 && IE_ALPHABET[k2] == 'W') return true; // D6W
   return k0 >= IE_FIRST_LETTER && k1 <= 9 && k2 <= 9;
}

static bool ie_parse (const char *str, bool partial, uint64_t *out) {
   if (!str) return false;

   int idx[7];
   int n = 0;
   const char *s = str;

   while (*s == ' ') s++;
   for (; n < 3 && *s && *s != ' '; n++, s++) {
      if ((idx[n] = ie_index(*s)) < 0) return false;
   }
   while (*s == ' ') s++;           // single optional gap before the identifier
   for (; n < 7 && *s; n++, s++) {
      if (n < 3) return false;      // a space inside the routing key
      if ((idx[n] = ie_index(*s)) < 0) return false;
   }
   while (*s == ' ') s++;
   if (*s != '\0') return false;     // trailing garbage / identifier too long

   if (n == 0) return false;
   if (!partial && n != 3 && n != 7) return false;

   uint64_t res = 0;
   for (int i = 0; i < n && i < 3; i++)
      SET_BITS64(res, IE_RK_POS + (2 - i) * IE_SYM_BITS, IE_SYM_BITS, (uint64_t) idx[i]);
   if (n > 3) {
      SET_BITS64(res, IE_HAS_UID_POS, 1, 1);
      for (int i = 3; i < n; i++)
         SET_BITS64(res, IE_UID_POS + (6 - i) * IE_SYM_BITS, IE_SYM_BITS, (uint64_t) idx[i]);
   }

   if (!partial && !ie_routing_key_ok(ie_rk(res, 0), ie_rk(res, 1), ie_rk(res, 2))) return false;

   *out = res;
   return true;
}

static char ie_char (unsigned i) { return i < IE_NSYM ? IE_ALPHABET[i] : '?'; }

static int ie_render (uint64_t payload, char *buf) {
   char *b = buf;
   for (int i = 0; i < 3; i++) *(b++) = ie_char(ie_rk(payload, i));

   if (GET_BITS64(payload, IE_HAS_UID_POS, 1)) {
      *(b++) = ' ';
      for (int i = 0; i < 4; i++) *(b++) = ie_char(ie_uid(payload, i));
   }
   *b = '\0';
   return (int) (b - buf);
}

static bool ie_valid (uint64_t payload) {
   if (GET_BITS64(payload, IE_USED_BITS, PC_PAYLOAD_BITS - IE_USED_BITS)) return false;
   if (!ie_routing_key_ok(ie_rk(payload, 0), ie_rk(payload, 1), ie_rk(payload, 2))) return false;

   if (!GET_BITS64(payload, IE_HAS_UID_POS, 1))
      return GET_BITS64(payload, IE_UID_POS, 20) == 0; // canonical: no stray identifier bits

   for (int i = 0; i < 4; i++)
      if (ie_uid(payload, i) >= IE_NSYM) return false;
   return true;
}

// ---- fragment ranges -------------------------------------------------
// A fragment is 1-3 routing-key characters, or a full routing key and 1-4
// identifier characters. Levels, most significant first:
//   0 rk0 (a letter)  1 rk1 (digit)  2 rk2 (digit, or W after D6)  |  3..6 uid
// with has_uid set exactly when the value is at level 3 or deeper. Same
// scheme as Canada: pad with the smallest symbols for lo; hi increments the
// last given level to its next allowed symbol, resets below, and carries up
// on overflow. D6W is the one routing key whose last character isn't a
// digit; it sorts between D69 and D70, so the successor of D69 is D6W and of
// D6W is D70.

static bool ie_next_symbol (int v[7], int level) {
   switch (level) {
   case 0:
      if (v[0] >= IE_NSYM - 1) return false;
      v[0]++;
      return true;
   case 1:
      if (v[1] >= 9) return false;
      v[1]++;
      return true;
   case 2:
      if (v[2] < 9) { v[2]++; return true; }
      if (v[2] == 9 && IE_ALPHABET[v[0]] == 'D' && v[1] == 6) { v[2] = ie_index('W'); return true; }
      return false;
   default:
      if (v[level] >= IE_NSYM - 1) return false;
      v[level]++;
      return true;
   }
}

static uint64_t ie_pack (const int v[7], bool has_uid) {
   uint64_t p = 0;
   for (int i = 0; i < 3; i++)
      SET_BITS64(p, IE_RK_POS + (2 - i) * IE_SYM_BITS, IE_SYM_BITS, (uint64_t) v[i]);
   if (has_uid) {
      SET_BITS64(p, IE_HAS_UID_POS, 1, 1);
      for (int i = 3; i < 7; i++)
         SET_BITS64(p, IE_UID_POS + (6 - i) * IE_SYM_BITS, IE_SYM_BITS, (uint64_t) v[i]);
   }
   return p;
}

static bool ie_range (const char *str, uint64_t *lo, uint64_t *hi, bool *unbounded) {
   if (!str) return false;

   int v[7] = { 0, 0, 0, 0, 0, 0, 0 };
   int depth = 0;
   const char *s = str;

   while (*s == ' ') s++;
   for (; depth < 3 && *s && *s != ' '; depth++, s++) {
      int i = ie_index(*s);
      if (i < 0) return false;
      if (depth == 0 && i < IE_FIRST_LETTER) return false;                 // a letter
      if (depth == 1 && i > 9) return false;                               // a digit
      if (depth == 2 && i > 9 &&
          !(IE_ALPHABET[i] == 'W' && IE_ALPHABET[v[0]] == 'D' && v[1] == 6)) return false;
      v[depth] = i;
   }
   while (*s == ' ') s++;
   for (; depth < 7 && *s; depth++, s++) {
      if (depth < 3) return false;                                         // space inside the routing key
      int i = ie_index(*s);
      if (i < 0) return false;
      v[depth] = i;
   }
   while (*s == ' ') s++;
   if (depth == 0 || *s != '\0') return false;

   // pad: a routing key needs a letter first, so its smallest is A
   int pad[7];
   for (int i = 0; i < 7; i++) pad[i] = v[i];
   if (depth < 1) pad[0] = IE_FIRST_LETTER;
   *lo = ie_pack(pad, depth >= 4);

   int w[7];
   for (int i = 0; i < 7; i++) w[i] = v[i];
   for (int level = depth - 1; ; level--) {
      if (ie_next_symbol(w, level)) {
         for (int j = level + 1; j < 7; j++) w[j] = 0;
         *hi = ie_pack(w, level >= 3);
         *unbounded = false;
         return true;
      }
      if (level == 0) { *unbounded = true; return true; }
   }
}

// Outcode: the routing key, dropping the unique identifier.
static uint64_t ie_outcode (uint64_t payload) {
   SET_BITS64(payload, IE_HAS_UID_POS, 1, 0);
   SET_BITS64(payload, IE_UID_POS, 20, 0);
   return payload;
}

const pc_encoder pc_ie_encoder = {
   .name         = "IE",
   .max_text_len = IE_MAX_TEXT_LEN,
   .parse        = ie_parse,
   .render       = ie_render,
   .valid        = ie_valid,
   .range        = ie_range,
   .outcode      = ie_outcode,
};
