// Standalone (no Postgres) tests for the encoders' range() hooks.
//
//   cc -std=c99 -DEXTVERSION=test -o t test_postal_code_range.c binfmt.c \
//      postal_code_fmt.c postal_code_{us,ca,fr,br,cz,lu,gb,ie}.c && ./t
//
// Two kinds of test:
//   1. hand-written cases for the edges that matter: skipped symbols,
//      carries, the one-off D6W, the top of a country
//   2. a randomised ORACLE for every format except GB: because each format
//      orders its payload exactly as its text sorts, a value is in a
//      fragment's range iff its text (separators removed) starts with the
//      fragment's. That is checked directly, for many random values,
//      fragments and near-miss values.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "postal_code.h"
#include "postal_code_fmt.h"

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { \
   printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

static const pc_encoder *E (const char *name) { return pc_formats[pc_format_by_name(name)]; }

static const char *R (const pc_encoder *e, uint64_t payload) {
   static char buf[4][32];
   static int n;
   char *b = buf[n++ & 3];
   e->render(payload, b);
   return b;
}

// range of `frag` in format `fmt` must be [lo, hi) as rendered text; hi == NULL means unbounded
static void RANGE_IS (const char *fmt, const char *frag, const char *lo_txt, const char *hi_txt) {
   const pc_encoder *e = E(fmt);
   uint64_t lo = 0, hi = 0;
   bool unb = false;
   if (!e->range(frag, &lo, &hi, &unb)) { printf("FAIL %s %-12s not accepted\n", fmt, frag); failures++; return; }
   int bad = 0;
   if (strcmp(R(e, lo), lo_txt) != 0) bad = 1;
   if (hi_txt == NULL ? !unb : (unb || strcmp(R(e, hi), hi_txt) != 0)) bad = 1;
   if (bad) {
      printf("FAIL %s %-12s want [%s, %s)  got [%s, %s)\n", fmt, frag, lo_txt, hi_txt ? hi_txt : "unbounded",
             R(e, lo), unb ? "unbounded" : R(e, hi));
      failures++;
   }
}

static void NOT_A_FRAGMENT (const char *fmt, const char *frag) {
   uint64_t lo, hi;
   bool unb;
   if (E(fmt)->range(frag, &lo, &hi, &unb)) { printf("FAIL %s %-12s accepted but should not be\n", fmt, frag); failures++; }
}

// ---------------------------------------------------------------- oracle

static void norm (const char *fmt, const char *text, char *out) {
   const char *s = text;
   if (strcmp(fmt, "LU") == 0 && (*s == 'L' || *s == 'l')) s++;       // the "L-" is decoration
   for (; *s; s++) if (isalnum((unsigned char) *s)) *out++ = (char) toupper((unsigned char) *s);
   *out = '\0';
}

static const char *pick (const char *set) { static char c[2]; c[0] = set[rand() % (int) strlen(set)]; c[1] = 0; return c; }

// a random valid value of the format, as canonical text
static void random_value (const char *fmt, char *out) {
   char t[32];
   if      (!strcmp(fmt, "US")) { if (rand() % 2) sprintf(t, "%05d", rand() % 100000); else sprintf(t, "%05d-%04d", rand() % 100000, 1 + rand() % 9999); }
   else if (!strcmp(fmt, "BR")) { if (rand() % 2) sprintf(t, "%05d", rand() % 100000); else sprintf(t, "%05d-%03d", rand() % 100000, rand() % 1000); }
   else if (!strcmp(fmt, "FR") || !strcmp(fmt, "CZ")) sprintf(t, "%05d", rand() % 100000);
   else if (!strcmp(fmt, "LU")) sprintf(t, "%04d", rand() % 10000);
   else if (!strcmp(fmt, "CA")) {
      char a[3][2], d[3];
      strcpy(a[0], pick("ABCEGHJKLMNPRSTVXY"));
      strcpy(a[1], pick("ABCEGHJKLMNPRSTVWXYZ"));
      strcpy(a[2], pick("ABCEGHJKLMNPRSTVWXYZ"));
      for (int i = 0; i < 3; i++) d[i] = (char) ('0' + rand() % 10);
      if (rand() % 2) sprintf(t, "%s%c%s", a[0], d[0], a[1]);
      else            sprintf(t, "%s%c%s%c%s%c", a[0], d[0], a[1], d[1], a[2], d[2]);
   } else { // IE
      char rk[4];
      if (rand() % 30 == 0) strcpy(rk, "D6W");
      else sprintf(rk, "%s%d%d", pick("ACDEFHKNPRTVWXY"), rand() % 10, rand() % 10);
      if (rand() % 2) strcpy(t, rk);
      else { sprintf(t, "%s", rk); for (int i = 0; i < 4; i++) strcat(t, pick("0123456789ACDEFHKNPRTVWXY")); }
   }
   uint64_t payload;
   const pc_encoder *e = E(fmt);
   if (!e->parse(t, false, &payload) || !e->valid(payload)) { printf("generator made invalid %s '%s'\n", fmt, t); failures++; strcpy(out, "0"); return; }
   e->render(payload, out);
}

static void oracle (const char *fmt, int nvalues) {
   const pc_encoder *e = E(fmt);
   int checked = 0, in_range = 0, invalid_hi = 0, unbounded_seen = 0;

   for (int v = 0; v < nvalues; v++) {
      char vt[32], vn[32];
      random_value(fmt, vt);
      norm(fmt, vt, vn);
      uint64_t vp;
      CHECK(e->parse(vt, false, &vp));

      // every prefix of the value's text, cut after the n-th alphanumeric character
      for (size_t n = 1; n <= strlen(vn); n++) {
         if (!strcmp(fmt, "LU") && n < 2) { /* "L" alone is not a fragment */ }
         char frag[32];
         size_t cut = 0, seen = 0;
         while (vt[cut] && seen < n) { if (isalnum((unsigned char) vt[cut])) seen++; cut++; }
         if (!strcmp(fmt, "LU")) { if (n < 2) continue; }   // text "L" -> no digits yet
         memcpy(frag, vt, cut); frag[cut] = '\0';

         uint64_t lo, hi = 0;
         bool unb;
         if (!e->range(frag, &lo, &hi, &unb)) { printf("FAIL %s: prefix '%s' of '%s' not accepted\n", fmt, frag, vt); failures++; continue; }

         char fn[32];
         norm(fmt, frag, fn);
         size_t fl = strlen(fn);

         CHECK(e->valid(lo));                       // lo is always a real value
         if (!unb) { CHECK(lo < hi); if (!e->valid(hi)) invalid_hi++; }
         else unbounded_seen++;
         CHECK(vp >= lo && (unb || vp < hi));        // a value is inside its own prefix's range

         // near misses: another random value sharing the first m characters with V
         for (int w = 0; w < 25; w++) {
            char wt[32], wn[32], mix[48];
            random_value(fmt, wt);
            norm(fmt, wt, wn);
            int m = (int) fl + (rand() % 3) - 1;
            if (m < 0) m = 0;
            if ((size_t) m > strlen(vn)) m = (int) strlen(vn);
            // rebuild W's text = V's first m alnum chars + W's remaining alnum chars (positions have the same classes)
            size_t wl = strlen(wn);
            if ((size_t) m > wl) continue;
            memcpy(mix, vn, (size_t) m);
            memcpy(mix + m, wn + m, wl - (size_t) m + 1);
            // re-parse; LU parse wants digits only
            uint64_t wp;
            const char *ptxt = mix;
            if (!e->parse(ptxt, false, &wp) || !e->valid(wp)) continue;   // spliced text isn't a value (e.g. IE D6W)
            char rendered[32], rn[32];
            e->render(wp, rendered);
            norm(fmt, rendered, rn);

            bool expect = strncmp(rn, fn, fl) == 0;
            bool got = wp >= lo && (unb || wp < hi);
            if (expect != got) {
               printf("FAIL %s: fragment '%s' [%s, %s): value '%s' expect %s got %s\n", fmt, frag,
                      R(e, lo), unb ? "unbounded" : R(e, hi), rendered, expect ? "in" : "out", got ? "in" : "out");
               failures++;
            }
            checked++;
            in_range += expect;
         }
      }
   }
   printf("%-3s oracle: %6d membership checks (%d inside), %d unbounded fragments, %d bounds that are not valid values\n",
          fmt, checked, in_range, unbounded_seen, invalid_hi);
   CHECK(invalid_hi == 0);
}

int main (void) {
   srand(12345);

   // ---- flat numeric: FR / CZ / LU
   RANGE_IS("FR", "750",   "75000", "75100");
   RANGE_IS("FR", "75",    "75000", "76000");
   RANGE_IS("FR", "75001", "75001", "75002");
   RANGE_IS("FR", "9",     "90000", NULL);
   RANGE_IS("FR", "99999", "99999", NULL);
   RANGE_IS("FR", "99998", "99998", "99999");
   NOT_A_FRAGMENT("FR", "");
   NOT_A_FRAGMENT("FR", "750000");
   NOT_A_FRAGMENT("FR", "75A");
   NOT_A_FRAGMENT("FR", "75001 CEDEX");
   RANGE_IS("CZ", "110",    "110 00", "111 00");
   RANGE_IS("CZ", "110 0",  "110 00", "110 10");
   RANGE_IS("CZ", "9",      "900 00", NULL);
   RANGE_IS("LU", "L-13",   "L-1300", "L-1400");
   RANGE_IS("LU", "13",     "L-1300", "L-1400");
   RANGE_IS("LU", "9",      "L-9000", NULL);
   NOT_A_FRAGMENT("LU", "L-");

   // ---- US: a ZIP5 fragment covers the bare ZIP5 and every +4 under it
   RANGE_IS("US", "902",         "90200",      "90300");
   RANGE_IS("US", "90210",       "90210",      "90211");
   RANGE_IS("US", "90210-1",     "90210-1000", "90210-2000");
   RANGE_IS("US", "90210-0",     "90210-0001", "90210-1000");   // 0000 is not a real add-on
   RANGE_IS("US", "90210-9999",  "90210-9999", "90211");        // last add-on: ends at the next ZIP5
   RANGE_IS("US", "90210-99",    "90210-9900", "90211");
   RANGE_IS("US", "99999",       "99999",      NULL);           // top of the country
   RANGE_IS("US", "99999-9999",  "99999-9999", NULL);
   RANGE_IS("US", "9",           "90000",      NULL);
   NOT_A_FRAGMENT("US", "90210-0000");
   NOT_A_FRAGMENT("US", "9021-1");

   // ---- BR: "000" is a real suffix
   RANGE_IS("BR", "0897",       "08970", "08980");
   RANGE_IS("BR", "08970",      "08970", "08971");
   RANGE_IS("BR", "08970-0",    "08970-000", "08970-100");
   RANGE_IS("BR", "08970-999",  "08970-999", "08971");
   RANGE_IS("BR", "99999-9",    "99999-900", NULL);
   RANGE_IS("BR", "9",          "90000", NULL);

   // ---- CA: skips D F I O Q U (and W Z first), carries, outcode values
   RANGE_IS("CA", "K",        "K0A",     "L0A");
   RANGE_IS("CA", "V",        "V0A",     "X0A");        // W is never a first letter
   RANGE_IS("CA", "Y",        "Y0A",     NULL);          // nothing after Y: Z is not a first letter
   RANGE_IS("CA", "K1",       "K1A",     "K2A");
   RANGE_IS("CA", "K9",       "K9A",     "L0A");         // digit carry into the first letter
   RANGE_IS("CA", "K1A",      "K1A",     "K1B");         // the bare FSA is the first value
   RANGE_IS("CA", "K1C",      "K1C",     "K1E");         // D is skipped
   RANGE_IS("CA", "K1Z",      "K1Z",     "K2A");         // Z is the last: carry
   RANGE_IS("CA", "K1A 0",    "K1A 0A0", "K1A 1A0");     // the LDU starts after the bare FSA
   RANGE_IS("CA", "K1A 9",    "K1A 9A0", "K1B");          // last LDU digit: carry out of the LDU lands on the next FSA's outcode
   RANGE_IS("CA", "K1A 0B",   "K1A 0B0", "K1A 0C0");
   RANGE_IS("CA", "K1A 0C",   "K1A 0C0", "K1A 0E0");
   RANGE_IS("CA", "K1A 0B1",  "K1A 0B1", "K1A 0B2");
   RANGE_IS("CA", "k1a0b1",   "K1A 0B1", "K1A 0B2");
   RANGE_IS("CA", "Y9Z 9Z9",  "Y9Z 9Z9", NULL);
   NOT_A_FRAGMENT("CA", "D");
   NOT_A_FRAGMENT("CA", "W1A");
   NOT_A_FRAGMENT("CA", "K1D");
   NOT_A_FRAGMENT("CA", "1");
   NOT_A_FRAGMENT("CA", "K1A 0B12");

   // ---- IE: 15-letter alphabet, D6W sits between D69 and D70
   RANGE_IS("IE", "A",         "A00",     "C00");        // there is no B
   RANGE_IS("IE", "A6",        "A60",     "A70");
   RANGE_IS("IE", "A65",       "A65",     "A66");
   RANGE_IS("IE", "A99",       "A99",     "C00");        // carry skips B
   RANGE_IS("IE", "D69",       "D69",     "D6W");        // the one routing key that is not letter-digit-digit
   RANGE_IS("IE", "D6W",       "D6W",     "D70");
   RANGE_IS("IE", "D6",        "D60",     "D70");        // and it is inside D6
   RANGE_IS("IE", "Y",         "Y00",     NULL);
   RANGE_IS("IE", "Y99",       "Y99",     NULL);
   RANGE_IS("IE", "A65 F",     "A65 F000", "A65 H000");   // identifier characters skip the missing letters too
   RANGE_IS("IE", "A65 Y",     "A65 Y000", "A66");        // last identifier letter carries to the next routing key
   RANGE_IS("IE", "A65 F4E2",  "A65 F4E2", "A65 F4E3");
   NOT_A_FRAGMENT("IE", "B");
   NOT_A_FRAGMENT("IE", "6");
   NOT_A_FRAGMENT("IE", "A6W");
   NOT_A_FRAGMENT("IE", "A 65");
   NOT_A_FRAGMENT("IE", "A65 F4E21");

   // ---- GB: hierarchical, reusing the UK type's own parser
   RANGE_IS("GB", "LS",         "LS0",         "LU0");      // the next area in the encoding
   RANGE_IS("GB", "LS1",        "LS1",         "LS10");     // district LS1 only, not LS1x
   RANGE_IS("GB", "LS24",       "LS24",        "LS25");
   RANGE_IS("GB", "LS19",       "LS19",        "LS1A");     // digits then letters
   RANGE_IS("GB", "LS1Z",       "LS1Z",        "LS2");
   RANGE_IS("GB", "LS0",        "LS0",         "LS01");     // there is no LS00
   RANGE_IS("GB", "SW1A",       "SW1A",        "SW1B");
   RANGE_IS("GB", "LS9",        "LS9",         "LS90");
   RANGE_IS("GB", "SW1A 1",     "SW1A 1AA",    "SW1A 2AA");
   RANGE_IS("GB", "SW1A 9",     "SW1A 9AA",    "SW1B");     // the last sector carries to the next outcode
   RANGE_IS("GB", "SW1A 1AA",   "SW1A 1AA",    "SW1A 1AB");
   RANGE_IS("GB", "SW1A 1AZ",   "SW1A 1AZ",    "SW1A 1BA");
   RANGE_IS("GB", "SW1A 1ZZ",   "SW1A 1ZZ",    "SW1A 2AA");
   RANGE_IS("GB", "sw1a1aa",    "SW1A 1AA",    "SW1A 1AB");
   RANGE_IS("GB", "GX",         "GX0",         NULL);       // the last area in the encoding
   RANGE_IS("GB", "ZE",         "ZE0",         "GX0");      // append-only area list: GX follows ZE in encoding order
   NOT_A_FRAGMENT("GB", "");
   NOT_A_FRAGMENT("GB", "Q1");
   NOT_A_FRAGMENT("GB", "LS00");

   // ---- randomised oracle against text-prefix semantics
   oracle("US", 150);
   oracle("BR", 150);
   oracle("FR", 100);
   oracle("CZ", 100);
   oracle("LU", 100);
   oracle("CA", 200);
   oracle("IE", 200);

   if (failures == 0) printf("all range tests passed\n");
   else               printf("%d failure(s)\n", failures);
   return failures ? 1 : 0;
}
