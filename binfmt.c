#include <stdlib.h>
#include <string.h>

#include "binfmt.h"
#include "postcode.h"
#include "dps.h"

// maximum number of characters to attempt to parse
#define POSTCODE_PARSE_LIMIT 32

#define IS_AZ(c) (c >= 'A' && c <= 'Z')
#define IS_09(c) (c >= '0' && c <= '9')

static inline int bcmp_ptr (const void *k, const void *v) {
   return strcmp(k, *((char **) v));
}


const char * postcode_version() { return STR(EXTVERSION); }


postcode postcode_parse (const char *str, bool partial) {
   postcode res = 0;

   char buf[POSTCODE_PARSE_LIMIT+1];
   int i = 0;
   for (const char *s = str; *s; s++) {
      if (i == POSTCODE_PARSE_LIMIT) return 0; // maximum length to parse
      if (*s >= 'a' && *s <= 'z') buf[i++] = *s - 32; // tr/[a-z]/[A-Z/
      else buf[i++] = *s;
   }
   buf[i] = '\0';

   // match area
   char key[3] = { 0 };
   size_t n = strspn(buf, "ABCDEFGHIJKLMNOPQRSTUVWXYZ");
   if (! (n == 1 || n == 2)) return 0;

   memcpy(key, buf, n);
   size_t area = 0;
   for (size_t i = 0; i < N_ELEMS(areas); i++) {
      if (strcmp(key, areas[i]) == 0) {
         area = i + 1;
         break;
      }
   }

   if (!area) return 0;
   SET_AREA(res, area);

   if (buf[n] == '\0') return partial ? res : 0;

   // match first digit of the district
   if (! IS_09(buf[n])) return 0;
   SET_DISTRICT1(res, buf[n++] - 47);

   if (buf[n] == '\0') return partial ? res : 0;

   // second character of district [0-9A-Z], or the sector [0-9]
   uint8_t tmp = 0;
   if      (IS_AZ(buf[n])) SET_DISTRICT2(res, buf[n++] - 47);
   else if (IS_09(buf[n])) tmp = buf[n++];

   while (buf[n] == ' ') n++; // skip any number of spaces

   if (buf[n] == '\0') {
      // prefer district LS48 over district LS4, sector 8
      if (tmp) SET_DISTRICT2(res, tmp - 47);
      return partial ? res : 0;
   }

   // sector or walk
   if (IS_09(buf[n])) {
      SET_SECTOR(res, buf[n++] - 47); // current char is sector
      if (tmp) {
         // permit district 0 but disallow as leading zero (eg. 0[0-9])
         if (GET_DISTRICT1(res) == 1 && IS_09(tmp)) return 0;
         SET_DISTRICT2(res, tmp - 47); // previous char was district
      }
      if (buf[n] =='\0') return partial ? res : 0;
   } else {
      if (! tmp) return 0;
      SET_SECTOR(res, tmp - 47); // previous char was sector
   }

   // walk
   if (strspn(&buf[n], "ABCDEFGHIJKLMNOPQRSTUVWXYZ") != 2) return 0;
   SET_WALK1(res, buf[n++] - 64);
   SET_WALK2(res, buf[n++] - 64);

   if (buf[n] != '\0') return 0;

   return res;
}


// Per-field validity, factored out of postcode_binchk() so
// postcode_render() (and postcode_to_char()'s template expansion, in
// postcode.c -- hence not `static`, declared in binfmt.h) can reuse the
// exact same bounds field-by-field (render '?' for a field that fails
// its own check) instead of the former all-or-nothing gate -- and so
// none of these can drift apart, the same discipline postcode_mask()/
// postcode_free_bits() already apply to each other in postcode.c.
// GET_DISTRICT2(p) == 0 (absent) is deliberately valid here, same as
// before: a one-digit district is a completely normal, fully-valid
// postcode, not a missing field.
bool valid_area      (postcode p) { return GET_AREA(p) >= 1 && GET_AREA(p) <= N_ELEMS(areas); }
bool valid_district1 (postcode p) { return GET_DISTRICT1(p) >= 1 && GET_DISTRICT1(p) <= 11; }
bool valid_district2 (postcode p) { return GET_DISTRICT2(p) <= 43 && !(GET_DISTRICT2(p) > 11 && GET_DISTRICT2(p) < 18); }
bool valid_sector     (postcode p) { return GET_SECTOR(p) >= 1 && GET_SECTOR(p) <= 11; }
bool valid_walk1      (postcode p) { return GET_WALK1(p) >= 1 && GET_WALK1(p) <= 27; }
bool valid_walk2      (postcode p) { return GET_WALK2(p) >= 1 && GET_WALK2(p) <= 27; }


// Never fails: a field that isn't a valid, renderable value (out of
// range, or -- for area/district1/sector/walk1/walk2, which are never
// legitimately absent in a full postcode -- simply unset) renders as
// '?' instead of aborting the whole render. This is what makes
// range_lower()/range_upper()'s boundary values (deliberately partial:
// see their own comment in postcode.c) safely renderable via ::text --
// previously postcode_out() raised ERRCODE_DATA_CORRUPTED for exactly
// this case, since it required a full postcode_binchk() pass before
// writing anything at all. district2 == 0 is the one field that's
// legitimately *absent* rather than invalid (a one-digit district is a
// normal, complete postcode) and is still correctly omitted entirely,
// not rendered as '?' -- unchanged from before.
//
// Bounds-checks each field before touching areas[] or writing its
// character, same as postcode_binchk() always has -- WRITE_AREA()
// indexes areas[GET_AREA(p)-1] directly with no bounds check of its own
// (see its own comment in postcode.h), so skipping straight to it for
// an out-of-range area would be an out-of-bounds read, not just a wrong
// answer. Every other field writes at most one placeholder-or-real
// character, so the worst case (all fields invalid: "?? ???" or
// shorter, area contributing only one '?' rather than its normal 1-2
// chars) is never wider than a normal fully-valid code -- the existing
// 9-byte buffer (8 visible chars + NUL) is still correctly sized.
int postcode_render (postcode p, char buf[9]) {
   char *b = buf;

   if (valid_area(p)) WRITE_AREA(b,p);
   else                *(b++) = '?';

   *(b++) = valid_district1(p) ? GET_DISTRICT1(p) + 47 : '?';

   if (GET_DISTRICT2(p))
      *(b++) = valid_district2(p) ? GET_DISTRICT2(p) + 47 : '?';

   *(b++) = ' ';

   *(b++) = valid_sector(p) ? GET_SECTOR(p) + 47 : '?';
   *(b++) = valid_walk1(p)  ? GET_WALK1(p)  + 64 : '?';
   *(b++) = valid_walk2(p)  ? GET_WALK2(p)  + 64 : '?';

   *b = '\0';
   return b - buf; // number of chars written -- always > 0 now
}


bool postcode_binchk (postcode p) {
   if (! valid_area(p))      return false;
   if (! valid_district1(p)) return false;
   if (! valid_district2(p)) return false;

   // Do not allow district 00
   if (GET_DISTRICT1(p) == 1 && GET_DISTRICT2(p) == 1) return false;

   if (! valid_sector(p)) return false;
   if (! valid_walk1(p))  return false;
   if (! valid_walk2(p))  return false;

   return true;
}


dps postcode_dps_parse (const char *str) {
   if (strnlen(str, 3) != 2) return 0;
   char key[3] = { 0 };
   memcpy(key, str, 2);
   if (key[1] >= 'a' && key[1] <= 'z') key[1] -= 32; // tr/[a-z]/[A-Z/
   char *d = bsearch(key, dpsuffix, N_ELEMS(dpsuffix), sizeof(char *), bcmp_ptr);
   if (!d) return 0;
   return ((char **) d) - ((char **) dpsuffix) + 1;
}


int postcode_dps_render (dps d, char buf[3]) {
   if (! postcode_dps_binchk(d)) return 0;
   memcpy(buf, dpsuffix[d-1], 2);
   buf[2] = '\0';
   return 2;
}


bool postcode_dps_binchk (dps d) {
   return d >= 1 && d <= N_ELEMS(dpsuffix);
}
