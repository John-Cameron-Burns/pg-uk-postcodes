// The parts patterns of the compiled formats US, CA, IE and BR, against their encoders. No Postgres needed:
//
//   (run from the source directory: it reads postcode--2.0.1--2.1.0.sql)
//   enc="postal_code_fmt.c postal_code_us.c postal_code_ca.c postal_code_fr.c postal_code_br.c postal_code_cz.c \
//        postal_code_lu.c postal_code_gb.c postal_code_ie.c binfmt.c"
//   cc -std=c99 -DEXTVERSION=test -o test_parts_compiled test_parts_compiled.c postal_code_pattern.c $enc && ./test_parts_compiled
//
// These formats have no field layout to compare with (GB does: test_parts_gb.c), so the checks are structural, on
// codes the encoder itself accepts, rendered by the encoder:
//   - the parts pattern accepts every one (it is only ever used on valid codes);
//   - the parts are in order, do not overlap, and each is at least one character;
//   - the encoder's own idea of the outcode (what outcode() returns) ends exactly where a part ends, so the
//     named parts agree with the format about where the first level stops;
//   - the pattern is unambiguous.
// How loose each pattern is, against the encoder, is reported.

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "postal_code_fmt.h"
#include "postal_code_pattern.h"
#include "test_parts_sql.h"

static int failures = 0;
static long checks = 0;
#define CHECK(cond) do { checks++; if (!(cond)) { if (failures < 20) printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

static void *xalloc (size_t n) { return malloc(n); }

typedef struct { const char *name; pc_format fmt; const pc_encoder *enc; pc_parts *parts; long valid, refused, refused_but_split; } fx;

static void try_text (fx *f, const char *text) {
   uint64_t payload = 0;
   bool ok = f->enc->parse(text, false, &payload) && f->enc->valid(payload);
   char canon[64];
   int s[PC_PAT_MAX_NAMES], e[PC_PAT_MAX_NAMES];
   if (!ok) {
      f->refused++;
      if (pc_parts_match(f->parts, text, s, e) == 1) f->refused_but_split++;
      return;
   }
   f->valid++;
   f->enc->render(payload, canon);
   CHECK(pc_parts_match(f->parts, canon, s, e) == 1);                      // accepts every valid code
   if (pc_parts_match(f->parts, canon, s, e) != 1) return;

   int n = pc_parts_count(f->parts), last_end = 0;
   for (int i = 0; i < n; i++) {
      if (s[i] < 0) continue;
      CHECK(e[i] > s[i]);                                                  // not empty
      CHECK(s[i] >= last_end);                                             // in order, no overlap
      last_end = e[i];
   }
   if (f->enc->outcode) {                                                  // the format's outcode ends where a part ends
      char outtext[64];
      f->enc->render(f->enc->outcode(payload), outtext);
      size_t ol = strlen(outtext);
      CHECK(strncmp(canon, outtext, ol) == 0);
      bool at_end_of_part = (ol == strlen(canon));
      for (int i = 0; i < n; i++) if (s[i] >= 0 && (size_t) e[i] == ol) at_end_of_part = true;
      CHECK(at_end_of_part);
   }
}

int main (void) {
   fx formats[] = { { "US", PC_FMT_US }, { "CA", PC_FMT_CA }, { "IE", PC_FMT_IE }, { "BR", PC_FMT_BR } };
   char err[200], re[4096], text[64];
   for (size_t k = 0; k < sizeof formats / sizeof *formats; k++) {
      fx *f = &formats[k];
      f->enc = pc_formats[f->fmt];
      if (!load_parts_pattern(f->name, re, sizeof re)) { printf("no parts pattern for %s\n", f->name); return 1; }
      f->parts = pc_parts_compile(re, xalloc, err, sizeof err);
      pc_pattern *pat = pc_pattern_compile(re, xalloc, err, sizeof err);
      if (!f->parts || !pat) { printf("%s: %s\n", f->name, err); return 1; }
      char msg[200];
      int amb = pc_parts_check(f->parts, pat, msg, sizeof msg);
      CHECK(amb == PC_CHECK_UNAMBIGUOUS);

      if (f->fmt == PC_FMT_US || f->fmt == PC_FMT_BR) {
         for (int z = 0; z < 100000; z++) {
            snprintf(text, sizeof text, "%05d", z); try_text(f, text);
            if (z % 7 == 0) {
               int ext = (z * 31) % 10000;
               if (f->fmt == PC_FMT_US) snprintf(text, sizeof text, "%05d-%04d", z, ext);
               else snprintf(text, sizeof text, "%05d-%03d", z, ext % 1000);
               try_text(f, text);
            }
         }
         try_text(f, "00000-0000"); try_text(f, "99999-9999"); try_text(f, "1234"); try_text(f, "123456");
      }
      else if (f->fmt == PC_FMT_CA) {
         for (int a = 0; a < 26; a++) for (int d = 0; d < 10; d++) for (int b = 0; b < 26; b++) {
            snprintf(text, sizeof text, "%c%d%c", 'A' + a, d, 'A' + b); try_text(f, text);
            for (int d2 = 0; d2 < 10; d2 += 3) for (int c = 0; c < 26; c += 5) {
               snprintf(text, sizeof text, "%c%d%c %d%c%d", 'A' + a, d, 'A' + b, d2, 'A' + c, (d2 + c) % 10);
               try_text(f, text);
            }
         }
      }
      else {   // IE: routing key, then optionally the 4-character unique identifier
         static const char sym[] = "ACDEFHKNPRTVWXY0123456789";
         for (int a = 0; a < 26; a++) for (int d = 0; d < 10; d++) {
            for (int third = 0; third < 11; third++) {
               char t = third < 10 ? (char) ('0' + third) : 'W';
               snprintf(text, sizeof text, "%c%d%c", 'A' + a, d, t); try_text(f, text);
               for (int u = 0; u < 400; u += 7) {
                  snprintf(text, sizeof text, "%c%d%c %c%c%c%c", 'A' + a, d, t, sym[u % 25], sym[(u / 3) % 25], sym[(u / 5) % 25], sym[(u / 7) % 25]);
                  try_text(f, text);
               }
            }
         }
         try_text(f, "D6W"); try_text(f, "D6W 1234");
      }
      printf("%s: parts pattern %s -- %ld valid codes all split; unambiguous check %d; format refused %ld strings, the pattern would split %ld of them (looser, which is fine)\n",
             f->name, "from the upgrade script", f->valid, amb, f->refused, f->refused_but_split);
      CHECK(f->valid > 1000);
   }
   printf("\n%ld checks, %d failures\n", checks, failures);
   return failures ? 1 : 0;
}
