#include <stdio.h>
#include <string.h>
#include <assert.h>

#include "postal_code.h"
#include "postal_code_fmt.h"
#include "binfmt.h"

static int failures = 0;

#define CHECK(cond) do { \
   if (!(cond)) { \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      failures++; \
   } \
} while (0)

// Country->format assignment is no longer compiled in (it's a SQL
// table now, see postal_code_country.c) -- this standalone harness
// tests each format's own encode/decode logic directly, so it just
// looks the format up by name. Every format built so far happens to
// be named after its primary country ("US", "CA", ...), so passing
// the same string as both cc and format name works out for every
// call site below; that's a coincidence of what's been built, not
// something this helper assumes in general.
static postal_code make (const char *cc, const char *text, bool *ok) {
   pc_format fmt = pc_format_by_name(cc);
   *ok = fmt != PC_FMT_UNKNOWN;
   if (!*ok) return 0;

   uint64_t payload = 0;
   *ok = pc_formats[fmt]->parse(text, false, &payload) && pc_formats[fmt]->valid(payload);
   if (!*ok) return 0;

   postal_code pc = 0;
   SET_COUNTRY(pc, pc_pack_country(cc[0], cc[1]));
   SET_FORMAT(pc, fmt);
   SET_PAYLOAD(pc, payload);
   return pc;
}

static void render (postal_code pc, char *buf, size_t buflen) {
   pc_format fmt = (pc_format) GET_FORMAT(pc);
   char iso2[2];
   pc_unpack_country((uint16_t) GET_COUNTRY(pc), iso2);
   int n = snprintf(buf, buflen, "%c%c-", iso2[0], iso2[1]);
   pc_formats[fmt]->render(GET_PAYLOAD(pc), buf + n);
}

int main (void) {
   char buf[32];
   bool ok;

   // --- US round trips ---
   postal_code us1 = make("US", "90210", &ok);
   CHECK(ok);
   render(us1, buf, sizeof buf);
   CHECK(strcmp(buf, "US-90210") == 0);

   postal_code us2 = make("US", "90210-1234", &ok);
   CHECK(ok);
   render(us2, buf, sizeof buf);
   CHECK(strcmp(buf, "US-90210-1234") == 0);

   // 0000 is not a real +4 add-on code
   postal_code us_bad = make("US", "90210-0000", &ok);
   CHECK(!ok);
   (void) us_bad;

   // --- Canada round trips ---
   postal_code ca1 = make("CA", "K1A 0B1", &ok);
   CHECK(ok);
   render(ca1, buf, sizeof buf);
   CHECK(strcmp(buf, "CA-K1A 0B1") == 0);

   // tolerant of no space and lowercase, same as UK's parser
   postal_code ca2 = make("CA", "k1a0b1", &ok);
   CHECK(ok);
   render(ca2, buf, sizeof buf);
   CHECK(strcmp(buf, "CA-K1A 0B1") == 0);

   // D is an excluded letter -- must be rejected
   postal_code ca_bad = make("CA", "D1A 0B1", &ok);
   CHECK(!ok);
   (void) ca_bad;

   // W is excluded as a FIRST letter only -- invalid there, fine elsewhere
   postal_code ca_w_first = make("CA", "W1A 0B1", &ok);
   CHECK(!ok);
   (void) ca_w_first;

   postal_code ca_w_mid = make("CA", "K1W 0B1", &ok);
   CHECK(ok);
   render(ca_w_mid, buf, sizeof buf);
   CHECK(strcmp(buf, "CA-K1W 0B1") == 0);

   // unknown format name (country->format assignment itself is a SQL
   // concern now -- see sql/postal_code.sql for that coverage)
   CHECK(pc_format_by_name("ZZ") == PC_FMT_UNKNOWN);
   CHECK(pc_format_by_name(NULL) == PC_FMT_UNKNOWN);

   // all-zero payload is a legitimate value in both formats (US
   // "00000" with no +4, CA "A0A 0A0") -- must not be mistaken for
   // a parse failure just because it happens to unpack to all zero
   // bits (this was a real bug: parse() used to signal failure by
   // returning 0, which collides with these).
   postal_code us_zero = make("US", "00000", &ok);
   CHECK(ok);
   render(us_zero, buf, sizeof buf);
   CHECK(strcmp(buf, "US-00000") == 0);

   postal_code ca_zero = make("CA", "A0A 0A0", &ok);
   CHECK(ok);
   render(ca_zero, buf, sizeof buf);
   CHECK(strcmp(buf, "CA-A0A 0A0") == 0);

   // --- CA FSA-only (no LDU) -- discovered to be the overwhelmingly
   // common real-world shape via GeoNames' worldwide postal code
   // table (1655 of 1657 CA rows are exactly this, not full 6-char
   // codes): a bare 3-character FSA is a complete, valid value in
   // its own right, not a fragment.
   postal_code ca_fsa = make("CA", "T0A", &ok);
   CHECK(ok);
   render(ca_fsa, buf, sizeof buf);
   CHECK(strcmp(buf, "CA-T0A") == 0);

   // 4 or 5 characters is neither a valid FSA-only nor a complete
   // FSA+LDU value -- must be rejected, not silently truncated/padded
   postal_code ca_4char = make("CA", "T0A0", &ok);
   CHECK(!ok);
   (void) ca_4char;

   // an FSA-only value sorts immediately before every fully-specified
   // value sharing that same FSA
   postal_code ca_fsa_full = make("CA", "T0A 0A0", &ok);
   CHECK(ok);
   CHECK(ca_fsa < ca_fsa_full);

   // --- ordering: country sorts as ISO alpha-2 text order ---
   CHECK(us1 != 0 && ca1 != 0);
   CHECK(GET_COUNTRY(ca1) < GET_COUNTRY(us1)); // "CA" < "US"
   CHECK(ca1 < us1);                           // whole 64-bit value follows suit

   // --- ordering: ZIP5-only interleaves immediately before its own +4s ---
   CHECK(us1 < us2); // "90210" then "90210-1234"

   postal_code us3 = make("US", "90211", &ok);
   CHECK(ok);
   CHECK(us2 < us3); // "90210-1234" sorts before "90211", matching text order

   // --- FR ---
   postal_code fr1 = make("FR", "75001", &ok);
   CHECK(ok);
   render(fr1, buf, sizeof buf);
   CHECK(strcmp(buf, "FR-75001") == 0);

   // CEDEX is real: "75054 CEDEX 01" carries a distinct 5-digit postcode
   // plus distribution routing that isn't part of the code. Accepted and
   // normalised away -- but ONLY exactly NNNNN [CEDEX [n]], not "anything
   // after the digits".
   const char *cedex_ok[] = { "75054 CEDEX 01", "75054 CEDEX 1", "75054 CEDEX", "75054  cedex  9 ", "75054 Cedex 20" };
   for (size_t i = 0; i < sizeof cedex_ok / sizeof cedex_ok[0]; i++) {
      postal_code c = make("FR", cedex_ok[i], &ok);
      CHECK(ok);
      render(c, buf, sizeof buf);
      CHECK(strcmp(buf, "FR-75054") == 0);
   }
   const char *cedex_bad[] = { "78078 CITYSSIMO", "75001 SP 07", "75001 AIR", "75001 foo", "75054 CEDEX 123",
                               "75054 CEDEX 1x", "75054 CEDEXX", "75054CEDEX", "75054 CEDEX1", "75054 CEDE" };
   for (size_t i = 0; i < sizeof cedex_bad / sizeof cedex_bad[0]; i++) {
      postal_code c = make("FR", cedex_bad[i], &ok);
      CHECK(!ok);
      (void) c;
   }

   // --- CZ: tolerant of the conventional space being present or not ---
   postal_code cz1 = make("CZ", "110 00", &ok);
   CHECK(ok);
   render(cz1, buf, sizeof buf);
   CHECK(strcmp(buf, "CZ-110 00") == 0);

   postal_code cz2 = make("CZ", "11000", &ok);
   CHECK(ok);
   CHECK(cz1 == cz2); // same value, with or without the space

   // --- LU: "L-" is part of the canonical form, input tolerates its absence ---
   postal_code lu1 = make("LU", "L-1311", &ok);
   CHECK(ok);
   render(lu1, buf, sizeof buf);
   CHECK(strcmp(buf, "LU-L-1311") == 0);

   postal_code lu2 = make("LU", "1311", &ok);
   CHECK(ok);
   CHECK(lu1 == lu2);

   // --- BR: optional suffix, "000" is a common REAL value, not a
   // sentinel for absence (unlike US's 0000) ---
   postal_code br1 = make("BR", "01310-100", &ok);
   CHECK(ok);
   render(br1, buf, sizeof buf);
   CHECK(strcmp(buf, "BR-01310-100") == 0);

   postal_code br_base = make("BR", "08970", &ok);
   CHECK(ok);
   render(br_base, buf, sizeof buf);
   CHECK(strcmp(buf, "BR-08970") == 0);

   postal_code br_common_000 = make("BR", "08970-000", &ok);
   CHECK(ok);
   render(br_common_000, buf, sizeof buf);
   CHECK(strcmp(buf, "BR-08970-000") == 0);
   CHECK(br_common_000 != br_base); // "-000" present is distinct from absent

   // base-only sorts immediately before every fully-specified value
   // sharing that base, same property as CA's FSA-only
   CHECK(br_base < br_common_000);

   // --- cross-value ordering: regression guard for a real bug where
   // has_ldu/has_suffix were placed as the single most-significant
   // bit, making every bare/coarser value sort before every suffixed
   // value REGARDLESS of base/FSA -- e.g. CA:T0A before CA:K1A 0B1
   // (wrong: T > K), or BR:08971 before BR:08970-999 (wrong: text
   // order puts 08970-999 first). A real mixed-country ORDER BY over
   // real GEONAMES-derived data caught this; these two checks pin it.
   postal_code ca_k1a_full = make("CA", "K1A 0B1", &ok);
   CHECK(ok);
   CHECK(ca_k1a_full < ca_fsa); // "K1A 0B1" sorts before "T0A": K < T

   postal_code br_08971 = make("BR", "08971", &ok);
   CHECK(ok);
   postal_code br_08970_999 = make("BR", "08970-999", &ok);
   CHECK(ok);
   CHECK(br_08970_999 < br_08971); // "08970-999" sorts before "08971": same text order

   // --- outcode-only is a complete, valid value (UK, IE, CA, US) ---
   // GeoNames: all 27,450 GB rows and all 139 IE rows are outcode-only.
   postal_code gb_full = make("GB", "SW1A 1AA", &ok);
   CHECK(ok);
   render(gb_full, buf, sizeof buf);
   CHECK(strcmp(buf, "GB-SW1A 1AA") == 0);

   // the payload is exactly the existing postcode type's value
   CHECK(GET_PAYLOAD(gb_full) == (uint64_t) postcode_parse("SW1A 1AA", false));

   postal_code gb_out = make("GB", "SW1A", &ok);
   CHECK(ok);
   render(gb_out, buf, sizeof buf);
   CHECK(strcmp(buf, "GB-SW1A") == 0);

   postal_code gb_out1 = make("GB", "ls24", &ok); // lower case, one-digit-plus-digit district
   CHECK(ok);
   render(gb_out1, buf, sizeof buf);
   CHECK(strcmp(buf, "GB-LS24") == 0);

   postal_code gb_short = make("GB", "M1", &ok);   // 1-letter area, 1-digit district
   CHECK(ok);
   render(gb_short, buf, sizeof buf);
   CHECK(strcmp(buf, "GB-M1") == 0);

   // an outcode sorts immediately before every full code in it, and
   // outcodes still sort against each other
   CHECK(gb_out < gb_full);
   postal_code gb_full2 = make("GB", "SW1A 2AA", &ok);
   CHECK(ok && gb_full < gb_full2);
   postal_code gb_next = make("GB", "SW1B", &ok);
   CHECK(ok && gb_full2 < gb_next);

   // in-between (sector, no unit) and area-only are fragments, not postcodes
   postal_code gb_sec = make("GB", "SW1A 1", &ok);
   CHECK(!ok);
   (void) gb_sec;
   postal_code gb_area = make("GB", "SW", &ok);
   CHECK(!ok);
   (void) gb_area;
   postal_code gb_bad = make("GB", "ZZ1 1AA", &ok);
   CHECK(!ok);
   (void) gb_bad;

   // --- IE (Eircode) ---
   postal_code ie_full = make("IE", "A65 F4E2", &ok);
   CHECK(ok);
   render(ie_full, buf, sizeof buf);
   CHECK(strcmp(buf, "IE-A65 F4E2") == 0);

   postal_code ie_nospace = make("IE", "a65f4e2", &ok);
   CHECK(ok && ie_nospace == ie_full);

   postal_code ie_rk = make("IE", "A65", &ok);
   CHECK(ok);
   render(ie_rk, buf, sizeof buf);
   CHECK(strcmp(buf, "IE-A65") == 0);
   CHECK(ie_rk < ie_full);

   postal_code ie_d6w = make("IE", "D6W", &ok); // the one routing key that isn't letter-digit-digit
   CHECK(ok);
   render(ie_d6w, buf, sizeof buf);
   CHECK(strcmp(buf, "IE-D6W") == 0);

   postal_code ie_next = make("IE", "A66", &ok);
   CHECK(ok && ie_full < ie_next); // routing key dominates the identifier

   postal_code ie_b = make("IE", "B65", &ok);        // B is not an Eircode letter
   CHECK(!ok);
   (void) ie_b;
   postal_code ie_d6x = make("IE", "D6X", &ok);      // only D6W is exempt
   CHECK(!ok);
   (void) ie_d6x;
   postal_code ie_6 = make("IE", "A65 F4E", &ok);    // identifier is exactly 4 characters
   CHECK(!ok);
   (void) ie_6;
   postal_code ie_o = make("IE", "A65 F4O2", &ok);   // O is not an Eircode letter
   CHECK(!ok);
   (void) ie_o;
   postal_code ie_sp = make("IE", "A 65", &ok);      // no space inside the routing key
   CHECK(!ok);
   (void) ie_sp;

   // --- full code required where the outcode is only implicit (FR, CZ, LU) ---
   postal_code fr_prefix = make("FR", "750", &ok);
   CHECK(!ok);
   (void) fr_prefix;
   postal_code cz_prefix = make("CZ", "110", &ok);
   CHECK(!ok);
   (void) cz_prefix;
   postal_code lu_prefix = make("LU", "L-13", &ok);
   CHECK(!ok);
   (void) lu_prefix;

   if (failures == 0) printf("all tests passed\n");
   else printf("%d failure(s)\n", failures);
   return failures ? 1 : 0;
}
