#include <stdint.h>
#include <stdbool.h>

#include "postcode.h"
#include "binfmt.h"
#include "postal_code_fmt.h"

// United Kingdom (also the Crown Dependencies GG/IM/JE, whose areas --
// GY, IM, JE -- are already in areas.h): the payload IS the existing
// 32-bit `postcode` value (postcode.h's layout, unchanged), carried in
// the low 32 bits. Parsing reuses postcode_parse() and the valid_*()
// field checks from binfmt.c; nothing about the UK encoding is
// reimplemented here, so the two types can't drift apart.
//
// Outcode-only ("SW1A", "LS24") is a complete, valid value, not a
// fragment. This costs nothing in the encoding: every UK field is
// 1-based (0 means "unset"), so an outcode is simply area+district
// with sector and walk left at 0, and it sorts immediately before
// every full postcode in that outcode. Real data agrees -- every one
// of GeoNames' 27,450 GB rows is outcode-only. What is NOT valid is
// the in-between ("SW1A 1": sector but no unit): that's a fragment,
// accepted only by the partial=true path.
//
//   31      24 23   20 19     14 13     10 9      5 4       0
//  +----------+-------+---------+---------+--------+---------+
//  | area:8   | d1:4  |  d2:6   | sector:4| walk1:5| walk2:5 |
//  +----------+-------+---------+---------+--------+---------+

#define GB_USED_BITS 32
#define GB_MAX_TEXT_LEN 8 // "SW1A 1AA"

static inline postcode gb_get (uint64_t payload) {
   return (postcode) GET_BITS64(payload, 0, GB_USED_BITS);
}

static inline bool gb_no_inward (postcode p) {
   return !GET_SECTOR(p) && !GET_WALK1(p) && !GET_WALK2(p);
}

static bool gb_fields_ok (postcode p) {
   if (!valid_area(p) || !valid_district1(p) || !valid_district2(p)) return false;
   if (GET_DISTRICT1(p) == 1 && GET_DISTRICT2(p) == 1) return false; // district 00
   if (gb_no_inward(p)) return true; // outcode only
   return valid_sector(p) && valid_walk1(p) && valid_walk2(p);
}

static bool gb_parse (const char *str, bool partial, uint64_t *out) {
   if (!str) return false;

   postcode p = postcode_parse(str, true);
   if (p == 0) return false;

   if (!partial && !gb_fields_ok(p)) return false;

   *out = p;
   return true;
}

static int gb_render (uint64_t payload, char *buf) {
   postcode p = gb_get(payload);
   char *b = buf;

   if (valid_area(p)) {
      const char *a = areas[GET_AREA(p) - 1];
      *(b++) = a[0];
      if (a[1]) *(b++) = a[1];
   } else {
      *(b++) = '?';
   }

   *(b++) = valid_district1(p) ? (char) (GET_DISTRICT1(p) + 47) : '?';
   if (GET_DISTRICT2(p))
      *(b++) = valid_district2(p) ? (char) (GET_DISTRICT2(p) + 47) : '?';

   if (!gb_no_inward(p)) {
      *(b++) = ' ';
      *(b++) = valid_sector(p) ? (char) (GET_SECTOR(p) + 47) : '?';
      *(b++) = valid_walk1(p)  ? (char) (GET_WALK1(p)  + 64) : '?';
      *(b++) = valid_walk2(p)  ? (char) (GET_WALK2(p)  + 64) : '?';
   }

   *b = '\0';
   return (int) (b - buf);
}

static bool gb_valid (uint64_t payload) {
   if (GET_BITS64(payload, GB_USED_BITS, PC_PAYLOAD_BITS - GB_USED_BITS)) return false;
   return gb_fields_ok(gb_get(payload));
}

const pc_encoder pc_gb_encoder = {
   .name         = "GB",
   .max_text_len = GB_MAX_TEXT_LEN,
   .parse        = gb_parse,
   .render       = gb_render,
   .valid        = gb_valid,
};
