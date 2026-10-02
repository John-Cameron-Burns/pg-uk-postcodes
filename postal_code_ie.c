#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "postal_code_fmt.h"

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

const pc_encoder pc_ie_encoder = {
   .name         = "IE",
   .max_text_len = IE_MAX_TEXT_LEN,
   .parse        = ie_parse,
   .render       = ie_render,
   .valid        = ie_valid,
};
