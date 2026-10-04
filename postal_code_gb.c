#include <stdint.h>
#include <string.h>
#include <stdbool.h>

#include "postcode.h"
#include "binfmt.h"
#include "postal_code_fmt.h"
#include "postal_code_range.h"

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

// Royal Mail's letter rules (BS 7666). The shared UK parser and the `postcode` type do not enforce them
// -- that type stays as lenient as it always was -- but postal_code's GB format does, so a typo such as
// "NG12 4FO" (letter O for zero, which really occurs) is rejected rather than stored:
//   unit letters         A B D E F G H J L N P Q R S T U W X Y Z   (never C I K M O V)
//   A9A  (1-letter area) the letter after the digit is one of A-H J K P S-U W
//   AA9A (2-letter area) the letter after the digit is one of A B E H M N P R V-Y
// Letters are held as 1..26 (A = 1), the fields' own encoding.
static const char GB_THIRD[]  = "ABCDEFGHJKPSTUW";
static const char GB_FOURTH[] = "ABEHMNPRVWXY";
static const char GB_UNIT[]   = "ABDEFGHJLNPQRSTUWXYZ";

static bool in_set (const char *set, unsigned letter) {
   return letter >= 1 && letter <= 26 && strchr(set, (int) ('A' + letter - 1)) != NULL;
}
static bool gb_unit_ok (unsigned v) { return in_set(GB_UNIT, v); }

// d2 is the district's second field: 0 none, 1..10 the digits 0-9, 18..43 the letters A-Z
static bool gb_d2_letter_ok (unsigned area, unsigned d2) {
   if (d2 < 18) return true;
   const char *a = areas[area - 1];
   return in_set(a[1] ? GB_FOURTH : GB_THIRD, d2 - 17);
}

static bool gb_fields_ok (postcode p) {
   if (!valid_area(p) || !valid_district1(p) || !valid_district2(p)) return false;
   if (GET_DISTRICT1(p) == 1 && GET_DISTRICT2(p) == 1) return false; // district 00
   if (!gb_d2_letter_ok(GET_AREA(p), GET_DISTRICT2(p))) return false;
   if (gb_no_inward(p)) return true; // outcode only
   return valid_sector(p) && valid_walk1(p) && valid_walk2(p) &&
          gb_unit_ok(GET_WALK1(p)) && gb_unit_ok(GET_WALK2(p));
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

// ---- fragment ranges -------------------------------------------------
// A fragment is an area ("SW"), an outcode ("SW1A", "LS24"), an outcode and
// sector ("SW1A 1"), or a full postcode, parsed by the same postcode_parse()
// the type itself uses -- so "LS1" is district LS1 only, not LS1x (the UK
// rule: all available digits go to the district unless a space says
// otherwise). Levels: area, district, sector, walk. lo pads the missing
// levels with their smallest values; hi is the successor at the last given
// level, carrying upward. A successor at sector or above lands on an
// OUTCODE (sector and walk zero) because the outcode sorts before the
// sectors beneath it; a successor within a sector lands on a full code.
//
// District order within a district-1 digit is: none, 0-9, A-Z (the order the
// fields already compare in), and "x00" is not a district. The area list is
// append-only and not in alphabetical order after the original entries (GX
// was added after ZE), so the "next area" is the next in ENCODING order --
// the same order the values themselves compare in, so tiling still holds.

typedef struct { unsigned area, d1, d2, sec, w1, w2; } gbf;

static postcode gb_make (const gbf *f) {
   postcode p = 0;
   SET_AREA(p, f->area);
   SET_DISTRICT1(p, f->d1);
   SET_DISTRICT2(p, f->d2);
   SET_SECTOR(p, f->sec);
   SET_WALK1(p, f->w1);
   SET_WALK2(p, f->w2);
   return p;
}

static bool gb_next_area (gbf *f) {
   if (f->area >= N_ELEMS(areas)) return false;
   f->area++;
   f->d1 = 1; f->d2 = 0; f->sec = f->w1 = f->w2 = 0;
   return true;
}

static bool gb_next_district (gbf *f) {
   unsigned n;
   if      (f->d2 == 0)  n = (f->d1 == 1) ? 2 : 1;   // no "x00"
   else if (f->d2 < 10)  n = f->d2 + 1;
   else if (f->d2 == 10) n = 18;                      // after 9 comes A
   else if (f->d2 < 43)  n = f->d2 + 1;
   else                  n = 0;                       // after Z: carry
   while (n >= 18 && !gb_d2_letter_ok(f->area, n)) n = n < 43 ? n + 1 : 0;   // skip letters this area never uses
   if (n) {
      f->d2 = n;
   } else if (f->d1 < 10) {
      f->d1++; f->d2 = 0;
   } else {
      return gb_next_area(f);
   }
   f->sec = f->w1 = f->w2 = 0;
   return true;
}

static bool gb_next_sector (gbf *f) {
   if (f->sec < 10) { f->sec++; f->w1 = f->w2 = 1; return true; }
   return gb_next_district(f);
}

static bool gb_next_walk (gbf *f) {
   unsigned w = f->w2 + 1;
   while (w <= 26 && !gb_unit_ok(w)) w++;             // skip C I K M O V
   if (w <= 26) { f->w2 = w; return true; }
   w = f->w1 + 1;
   while (w <= 26 && !gb_unit_ok(w)) w++;
   if (w <= 26) { f->w1 = w; f->w2 = 1; return true; }    // 1 = 'A', always allowed
   return gb_next_sector(f);
}

static bool gb_range (const char *str, uint64_t *lo, uint64_t *hi, bool *unbounded) {
   if (!str) return false;

   // A fragment may stop part-way through the unit: "M14 6Q" is a prefix of "M14 6QA".."M14 6QZ".
   // The UK parser wants both unit letters, so peel the single letter off and set it afterwards. Only
   // when a space separates the sector digit, otherwise "SW1A" (district 1A) would be misread.
   char buf[16];
   unsigned first_letter = 0;
   size_t n = strlen(str);
   if (n >= 3 && n < sizeof buf && str[n - 3] == ' ' && str[n - 2] >= '0' && str[n - 2] <= '9' &&
       ((str[n - 1] >= 'A' && str[n - 1] <= 'Z') || (str[n - 1] >= 'a' && str[n - 1] <= 'z'))) {
      memcpy(buf, str, n - 1);
      buf[n - 1] = '\0';
      first_letter = (unsigned) ((str[n - 1] & ~0x20) - 64);
      str = buf;
   }

   postcode b = postcode_parse(str, true);
   if (b == 0 || !valid_area(b)) return false;
   if (first_letter) {
      if (!GET_SECTOR(b) || GET_WALK1(b)) return false;
      SET_WALK1(b, first_letter);
   }
   if (GET_DISTRICT1(b) &&
       (!valid_district1(b) || !valid_district2(b) ||
        (GET_DISTRICT1(b) == 1 && GET_DISTRICT2(b) == 1))) return false;
   if (GET_SECTOR(b) && !valid_sector(b)) return false;
   // a unit may be only its first letter ("M14 6Q", a prefix of "M14 6QA"): walk2 unset
   if (GET_WALK1(b) && !(valid_walk1(b) && gb_unit_ok(GET_WALK1(b)))) return false;
   if (GET_WALK2(b) && !(valid_walk2(b) && gb_unit_ok(GET_WALK2(b)))) return false;
   if (!gb_d2_letter_ok(GET_AREA(b), GET_DISTRICT2(b))) return false;

   gbf f = { GET_AREA(b), GET_DISTRICT1(b), GET_DISTRICT2(b),
             GET_SECTOR(b), GET_WALK1(b), GET_WALK2(b) };
   bool ok;

   if (f.w1 && !f.w2) {                             // sector + the unit's first letter
      f.w2 = 1;
      *lo = gb_make(&f);
      unsigned nw = f.w1 + 1;                      // the next first letter that is allowed
      while (nw <= 26 && !gb_unit_ok(nw)) nw++;
      if (nw <= 26) { f.w1 = nw; ok = true; } else ok = gb_next_sector(&f);
   } else if (f.w1) {                               // a full postcode
      *lo = gb_make(&f);
      ok = gb_next_walk(&f);
   } else if (f.sec) {                              // outcode + sector
      f.w1 = f.w2 = 1;
      *lo = gb_make(&f);
      f.w1 = f.w2 = 0;
      ok = gb_next_sector(&f);
   } else if (f.d1) {                               // an outcode: the outcode value itself sorts first
      *lo = gb_make(&f);
      ok = gb_next_district(&f);
   } else {                                         // an area
      f.d1 = 1;
      *lo = gb_make(&f);
      ok = gb_next_area(&f);
   }

   *unbounded = !ok;
   if (ok) *hi = gb_make(&f);
   return true;
}

// Outcode: area and district, dropping sector and unit.
static uint64_t gb_outcode (uint64_t payload) {
   postcode p = gb_get(payload);
   SET_SECTOR(p, 0);
   SET_WALK1(p, 0);
   SET_WALK2(p, 0);
   return p;
}

const pc_encoder pc_gb_encoder = {
   .name         = "GB",
   .max_text_len = GB_MAX_TEXT_LEN,
   .parse        = gb_parse,
   .render       = gb_render,
   .valid        = gb_valid,
   .range        = gb_range,
   .outcode      = gb_outcode,
};
