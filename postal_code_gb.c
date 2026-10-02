#include <stdint.h>
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
   if (f->w2 < 26) { f->w2++; return true; }
   if (f->w1 < 26) { f->w1++; f->w2 = 1; return true; }
   return gb_next_sector(f);
}

static bool gb_range (const char *str, uint64_t *lo, uint64_t *hi, bool *unbounded) {
   if (!str) return false;
   postcode b = postcode_parse(str, true);
   if (b == 0 || !valid_area(b)) return false;
   if (GET_DISTRICT1(b) &&
       (!valid_district1(b) || !valid_district2(b) ||
        (GET_DISTRICT1(b) == 1 && GET_DISTRICT2(b) == 1))) return false;
   if (GET_SECTOR(b) && !valid_sector(b)) return false;
   if (GET_WALK1(b) && !(valid_walk1(b) && valid_walk2(b))) return false;

   gbf f = { GET_AREA(b), GET_DISTRICT1(b), GET_DISTRICT2(b),
             GET_SECTOR(b), GET_WALK1(b), GET_WALK2(b) };
   bool ok;

   if (f.w1) {                                      // a full postcode
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

const pc_encoder pc_gb_encoder = {
   .name         = "GB",
   .max_text_len = GB_MAX_TEXT_LEN,
   .parse        = gb_parse,
   .render       = gb_render,
   .valid        = gb_valid,
   .range        = gb_range,
};
