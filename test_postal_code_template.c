// Standalone tests for the templated format (postal_code_template.c), no
// Postgres needed. Build and run:
//
//   cc -std=c99 -Wall -Wpedantic -DEXTVERSION=test -o test_postal_code_template \
//      test_postal_code_template.c postal_code_template.c binfmt.c postal_code_fmt.c \
//      postal_code_{us,ca,fr,br,cz,lu,gb,ie}.c && ./test_postal_code_template
//
// What it checks, over a spread of small templates:
//   - text order == payload order, and render/parse round-trip, separators
//     optional, either case;
//   - every fragment (every prefix of every sampled value) gives exactly the
//     range a brute-force "which values start with this text" would, found
//     by binary search over the (ordered) payload space;
//   - it agrees with the compiled US and CZ encoders on canonical text;
//   - what is and isn't a template.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "postal_code_template.h"
#include "postal_code_fmt.h"

static int failures = 0;
static long checks = 0;

#define CHECK(cond) do { \
   checks++; \
   if (!(cond)) { \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      failures++; \
   } \
} while (0)

static void strip (const char *in, char *out) {
   while (*in) {
      if (*in != ' ' && *in != '-') *out++ = *in;
      in++;
   }
   *out = '\0';
}

static void stripped_of (const pc_template *t, uint64_t p, char *out) {
   char buf[64];
   pc_template_render(t, p, buf);
   strip(buf, out);
}

// first p in [0, total] whose stripped text compares >= frag (on frag's length)
// when strict is false, or > frag (i.e. does not start with it) when strict is true
static uint64_t bound (const pc_template *t, const char *frag, bool strict) {
   uint64_t lo = 0, hi = t->total;
   size_t n = strlen(frag);
   while (lo < hi) {
      uint64_t mid = lo + (hi - lo) / 2;
      char s[64];
      stripped_of(t, mid, s);
      int c = strncmp(s, frag, n);
      bool before = strict ? c <= 0 : c < 0;
      if (before) lo = mid + 1; else hi = mid;
   }
   return lo;
}

static void check_fragment (const pc_template *t, const char *frag) {
   char sf[64];
   strip(frag, sf);
   uint64_t elo = bound(t, sf, false), ehi = bound(t, sf, true);

   uint64_t lo = 0, hi = 0;
   bool unb = false;
   bool ok = pc_template_range(t, frag, &lo, &hi, &unb);
   if (elo == ehi) { // nothing starts with it: only possible for text that is not a fragment
      CHECK(!ok);
      return;
   }
   CHECK(ok);
   if (!ok) { printf("   %s: fragment \"%s\"\n", t->spec, frag); return; }
   bool good = lo == elo && (ehi == t->total ? unb : (!unb && hi == ehi));
   CHECK(good);
   if (!good)
      printf("   %s: fragment \"%s\": got [%llu,%llu)%s, want [%llu,%llu)\n", t->spec, frag,
             (unsigned long long) lo, (unsigned long long) hi, unb ? " unbounded" : "",
             (unsigned long long) elo, (unsigned long long) ehi);
}

static void test_template (const char *spec, uint64_t sample_every) {
   pc_template t;
   char err[128];
   CHECK(pc_template_compile(spec, &t, err, sizeof err));
   if (failures && 0) return;

   uint64_t step = sample_every ? sample_every : 1;
   char prev[64] = "";
   char buf[64], back[64];
   uint64_t p, got;

   // ordering and round trip, over the whole space when it is small
   for (p = 0; p < t.total; p += (t.total <= 20000 ? 1 : step)) {
      pc_template_render(&t, p, buf);
      CHECK(pc_template_valid(&t, p));
      CHECK(pc_template_parse(&t, buf, &got) && got == p);

      strip(buf, back);
      CHECK(pc_template_parse(&t, back, &got) && got == p);        // separators optional
      for (char *c = back; *c; c++) if (*c >= 'A' && *c <= 'Z') *c = (char) (*c + 32);
      CHECK(pc_template_parse(&t, back, &got) && got == p);        // lower case

      char cur[64];
      strip(buf, cur);
      if (t.total <= 20000) {                                       // adjacent values only when consecutive
         if (p) CHECK(strcmp(prev, cur) < 0);
         strcpy(prev, cur);
      }
      if (t.has_tail) {
         uint64_t oc = pc_template_outcode(&t, p);
         CHECK(oc <= p && oc % t.mult == 0 && pc_template_valid(&t, oc));
         CHECK(pc_template_outcode(&t, oc) == oc);
         char ob[64];
         pc_template_render(&t, oc, ob);
         CHECK(strncmp(buf, ob, strlen(ob)) == 0);
      }
   }
   CHECK(!pc_template_valid(&t, t.total));
   CHECK(!pc_template_valid(&t, (uint64_t) 1 << 47) || t.total > ((uint64_t) 1 << 47));

   // fragments: every prefix (raw, and stripped) of sampled values
   srand(12345);
   long n = t.total <= 3000 ? (long) t.total : 400;
   for (long i = 0; i < n; i++) {
      p = t.total <= 3000 ? (uint64_t) i : ((uint64_t) rand() * 65536u + (uint64_t) rand()) % t.total;
      pc_template_render(&t, p, buf);
      size_t len = strlen(buf);
      for (size_t k = 1; k <= len; k++) {
         char f[64];
         memcpy(f, buf, k);
         f[k] = '\0';
         check_fragment(&t, f);
      }
      strip(buf, back);
      for (size_t k = 1; k <= strlen(back); k++) {
         char f[64];
         memcpy(f, back, k);
         f[k] = '\0';
         check_fragment(&t, f);
      }
   }

   // not fragments
   uint64_t lo, hi;
   bool unb;
   CHECK(!pc_template_range(&t, "", &lo, &hi, &unb));
   CHECK(!pc_template_range(&t, "?", &lo, &hi, &unb));
   pc_template_render(&t, t.total - 1, buf);
   char longer[80];
   snprintf(longer, sizeof longer, "%s1", buf);
   CHECK(!pc_template_range(&t, longer, &lo, &hi, &unb));
   CHECK(!pc_template_parse(&t, longer, &got));
   CHECK(!pc_template_parse(&t, "", &got));
}

static void test_agrees_with_compiled (void) {
   pc_template cz, us, br;
   char err[128];
   CHECK(pc_template_compile("NNN NN", &cz, err, sizeof err));
   CHECK(pc_template_compile("NNNNN[-NNNN]", &us, err, sizeof err));
   CHECK(pc_template_compile("NNNNN[-NNN]", &br, err, sizeof err));

   struct { const pc_template *t; const char *name; } pairs[] = { {&cz, "CZ"}, {&us, "US"}, {&br, "BR"} };
   srand(777);
   for (int i = 0; i < 3; i++) {
      const pc_encoder *e = pc_formats[pc_format_by_name(pairs[i].name)];
      for (int n = 0; n < 20000; n++) {
         char s[32];
         int d = rand() % 100000, d4 = 1 + rand() % 9999;   // the US encoder reserves +0000, a template has no such rule
         switch (i) {
         case 0:  snprintf(s, sizeof s, "%03d %02d", d / 100, d % 100); break;
         case 1:  if (n & 1) snprintf(s, sizeof s, "%05d-%04d", d, d4); else snprintf(s, sizeof s, "%05d", d); break;
         default: if (n & 1) snprintf(s, sizeof s, "%05d-%03d", d, d4 % 1000); else snprintf(s, sizeof s, "%05d", d); break;
         }
         uint64_t a, b;
         bool ta = pc_template_parse(pairs[i].t, s, &a);
         bool eb = e->parse(s, false, &b) && e->valid(b);
         CHECK(ta == eb);
         if (ta && eb) {
            char ra[64], rb[64];
            pc_template_render(pairs[i].t, a, ra);
            e->render(b, rb);
            CHECK(strcmp(ra, rb) == 0);
            CHECK(strcmp(ra, s) == 0);
            if (e->outcode) {                            // the same outcode, as text
               pc_template_render(pairs[i].t, pc_template_outcode(pairs[i].t, a), ra);
               e->render(e->outcode(b), rb);
               CHECK(strcmp(ra, rb) == 0);
            }
         }
      }
   }
}

static void test_compile (void) {
   pc_template t;
   char err[128];
   const char *good[] = {
      "N", "NN", "NNN NN", "NN-NNN", "NNNN AA", "AAAA NNNN", "X", "XXXXXXXXX", "NNNNNNNNNNNNNN",
      "NNNNN[-NNNN]", "ANA[ NAN]", "NNNNNNN[NNNNNNN]", "NNN[NN]", "XXX[ XXX]", "N[ N]",
      "CCNNNN", "CC NNNN", "CC-NNNN", "CCN-NNNN", "CCNN NNN", "CCNNN[N]",
   };
   for (size_t i = 0; i < sizeof good / sizeof *good; i++) {
      bool ok = pc_template_compile(good[i], &t, err, sizeof err);
      CHECK(ok);
      if (!ok) printf("   \"%s\": %s\n", good[i], err);
      else CHECK(strcmp(t.spec, good[i]) == 0);
   }
   const char *bad[] = {
      "", "n", "NNa", "NN?", " NN", "-NN", "NN ", "NN-", "NN  NN", "N--N", "NN [NN]", "NN[ ]", "NN[]", "[NN]", "NN[NN",
      "NN]", "NN[N][N]", "NN[N]N", "NN[NN]]", "NN[N[N]]", "XXXXXXXXXX", "NNNNNNNNNNNNNNN", "NNNNNNNN[NNNNNNN]",
      "NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN", "NN[N ]",
      "CC", "CC ", "CC-", "CC[N]", "NCCN", "CNNNN", "CCC", "CC  NN",
   };
   for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
      bool ok = pc_template_compile(bad[i], &t, err, sizeof err);
      CHECK(!ok);
      if (ok) printf("   accepted \"%s\"\n", bad[i]);
      else CHECK(*err);
   }

   // sizes
   CHECK(pc_template_compile("NNNNN[-NNNN]", &t, err, sizeof err) && t.head_space == 100000 && t.tail_space == 10000 &&
         t.total == 100000ull * 10001);
   CHECK(pc_template_compile("ANA[ NAN]", &t, err, sizeof err) && t.head_space == 26ull * 10 * 26 && t.tail_space == 10ull * 26 * 10);
}

static void test_cc_prefix (void) {
   pc_template t, plain;
   char err[128];
   CHECK(pc_template_compile("CCNNNN", &t, err, sizeof err) && t.cc_prefix && t.nitems == 4 && t.total == 10000);
   CHECK(pc_template_compile("NNNN", &plain, err, sizeof err) && !plain.cc_prefix);

   const char vg[2] = { 'V', 'G' };
   const char *skip[][2] = {      // text, expected remainder
      { "VG1110", "1110" }, { "vg1110", "1110" }, { "VG 1110", "1110" }, { "VG-1110", "1110" },
      { "1110", "1110" }, { "AB1110", "AB1110" }, { "V", "V" }, { "VG", "" }, { "", "" },
   };
   for (size_t i = 0; i < sizeof skip / sizeof *skip; i++)
      CHECK(strcmp(pc_template_skip_cc(&t, vg, skip[i][0]), skip[i][1]) == 0);
   CHECK(strcmp(pc_template_skip_cc(&plain, vg, "VG1110"), "VG1110") == 0);   // only when the template says so

   // the prefix changes nothing about the code itself
   uint64_t a, b;
   CHECK(pc_template_parse(&t, "1110", &a));
   CHECK(pc_template_parse(&t, pc_template_skip_cc(&t, vg, "VG-1110"), &b) && a == b);
   CHECK(!pc_template_parse(&t, "VG1110", &b));        // the core does not strip: the caller does
   char buf[16];
   pc_template_render(&t, a, buf);
   CHECK(strcmp(buf, "1110") == 0);                    // and it is not written back

   uint64_t lo, hi;
   bool unb;
   CHECK(pc_template_range(&t, pc_template_skip_cc(&t, vg, "VG11"), &lo, &hi, &unb) && lo == 1100 && hi == 1200 && !unb);

   // CC may be followed by the usual separators inside the code
   CHECK(pc_template_compile("CCN-NNNN", &t, err, sizeof err) && t.nitems == 6);
   CHECK(pc_template_parse(&t, pc_template_skip_cc(&t, vg, "VG1-1100"), &a));
   pc_template_render(&t, a, buf);
   CHECK(strcmp(buf, "1-1100") == 0);
}

int main (void) {
   test_cc_prefix();
   test_compile();

   // small enough to check exhaustively, with fragments from every value
   test_template("N", 0);
   test_template("NN", 0);
   test_template("NA", 0);
   test_template("XX", 0);
   test_template("NN-AN", 0);
   test_template("N[N]", 0);
   test_template("A[ N]", 0);
   test_template("NA[-AN]", 0);
   test_template("N[ N A]", 0);
   test_template("XN[NN]", 0);
   test_template("NNN NN", 0);
   test_template("AAA", 0);
   // larger: round trip and order are sampled, fragments from random values
   test_template("NNNNN[-NNNN]", 997);
   test_template("ANA[ NAN]", 313);
   test_template("XNN[ NA]", 997);
   test_template("NNNNNNNNNN", 99991);
   test_template("XXXXXXXXX", 1000000007ull);
   test_template("NNNNNNN[NNNNNNN]", 100000007ull);

   test_agrees_with_compiled();

   printf("%ld checks, %d failures\n", checks, failures);
   return failures != 0;
}
