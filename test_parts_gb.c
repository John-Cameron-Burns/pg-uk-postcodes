// The GB parts pattern against the compiled GB format. No Postgres needed:
//
//   enc="postal_code_fmt.c postal_code_us.c postal_code_ca.c postal_code_fr.c postal_code_br.c postal_code_cz.c \
//        postal_code_lu.c postal_code_gb.c postal_code_ie.c binfmt.c"
//   (run from the source directory: it reads postcode--2.0.1--2.1.0.sql)
//   cc -std=c99 -DEXTVERSION=test -o test_parts_gb test_parts_gb.c postal_code_pattern.c $enc && ./test_parts_gb
//
// The GB format keeps its code in the 32-bit `postcode` layout, so there is a ground truth for what the parts of a
// code are: the layout's own fields (area, district, sector, walk -- the names `to_char` uses). The parts pattern
// is only used to split codes that are already valid, so it must (1) accept every code the format accepts and
// (2) split each exactly as the fields say. It does not have to refuse everything the format refuses: the district's
// allowed letters depend on how many letters the area has, which one pattern cannot say without repeating a name in
// two alternative branches. How loose it is gets reported.

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "binfmt.h"
#include "postcode.h"
#include "postal_code_fmt.h"
#include "postal_code_pattern.h"
#include "test_parts_sql.h"

static int failures = 0;
static long checks = 0;
#define CHECK(cond) do { checks++; if (!(cond)) { if (failures < 20) printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

static void *xalloc (size_t n) { return malloc(n); }

int main (void) {
   const pc_encoder *gb = pc_formats[PC_FMT_GB];
   size_t na = sizeof areas / sizeof *areas;

   // the pattern that ships, from the upgrade script
   static char re[8192];
   if (!load_parts_pattern("GB", re, sizeof re)) { printf("cannot read the GB parts pattern from postcode--2.0.1--2.1.0.sql\n"); return 1; }
   // ... which must name every area the format knows
   for (size_t i = 0; i < na; i++) { CHECK(strstr(re, areas[i]) != NULL); }

   char err[200];
   pc_parts *pp = pc_parts_compile(re, xalloc, err, sizeof err);
   pc_pattern *pat = pc_pattern_compile(re, xalloc, err, sizeof err);
   if (!pp || !pat) { printf("pattern failed: %s\n", err); return 1; }
   char msg[200];
   int amb = pc_parts_check(pp, pat, msg, sizeof msg);
   printf("GB parts pattern: %zu areas, %llu codes in the pattern, ambiguity check %d (0 = none) %s\n",
          na, (unsigned long long) pat->total, amb, msg);
   CHECK(amb == PC_CHECK_UNAMBIGUOUS);

   // every outward-code shape for every area, then inward codes under each; compare with the format
   long accepted_by_format = 0, accepted_by_pattern_only = 0, tested_negative = 0, inward_tested = 0;
   static const char walkL[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
   for (size_t a = 0; a < na; a++) {
      char outs[2000][5]; int no = 0;
      for (int d1 = 0; d1 < 10; d1++) {
         snprintf(outs[no++], 5, "%s%d", areas[a], d1);
         for (int d2 = 0; d2 < 10; d2++) snprintf(outs[no++], 5, "%s%d%d", areas[a], d1, d2);
         for (int l = 0; l < 26; l++) snprintf(outs[no++], 5, "%s%d%c", areas[a], d1, walkL[l]);
      }
      for (int o = 0; o < no; o++) {
         uint64_t payload = 0;
         bool fmt_ok = gb->parse(outs[o], false, &payload) && gb->valid(payload);
         int s[PC_PAT_MAX_NAMES], e[PC_PAT_MAX_NAMES];
         int pm = pc_parts_match(pp, outs[o], s, e);
         if (!fmt_ok) { tested_negative++; if (pm == 1) accepted_by_pattern_only++; continue; }
         accepted_by_format++;
         CHECK(pm == 1);                                  // (1) accepts everything the format accepts
         if (pm != 1) continue;
         // (2) splits it as the fields say
         postcode p = (postcode) payload;
         char area[3] = "", dist[3] = "";
         strncpy(area, areas[GET_AREA(p) - 1], 2);
         dist[0] = (char) (GET_DISTRICT1(p) + 47);
         if (GET_DISTRICT2(p)) dist[1] = (char) (GET_DISTRICT2(p) + 47);
         char canon[16];
         gb->render(payload, canon);
         int s2[PC_PAT_MAX_NAMES], e2[PC_PAT_MAX_NAMES];
         CHECK(pc_parts_match(pp, canon, s2, e2) == 1);
         CHECK(strlen(area) == (size_t) (e2[0] - s2[0]) && strncmp(canon + s2[0], area, strlen(area)) == 0);
         CHECK(strlen(dist) == (size_t) (e2[1] - s2[1]) && strncmp(canon + s2[1], dist, strlen(dist)) == 0);
         CHECK(s2[2] < 0 && s2[3] < 0);                 // an outward code alone has no sector or walk

         // the inward codes under it: every sector with a spread of walks, and every walk pair for a few outcodes
         int step = (o % 37 == 0) ? 1 : 29;
         for (int sec = 0; sec < 10; sec++)
            for (int w = 0; w < 676; w += step) {
               char full[16];
               snprintf(full, sizeof full, "%s %d%c%c", outs[o], sec, walkL[w / 26], walkL[w % 26]);
               uint64_t fp = 0;
               bool ok2 = gb->parse(full, false, &fp) && gb->valid(fp);
               int s3[PC_PAT_MAX_NAMES], e3[PC_PAT_MAX_NAMES];
               int pm3 = pc_parts_match(pp, full, s3, e3);
               inward_tested++;
               if (!ok2) { tested_negative++; if (pm3 == 1) accepted_by_pattern_only++; continue; }
               accepted_by_format++;
               CHECK(pm3 == 1);
               if (pm3 != 1) continue;
               postcode q = (postcode) fp;
               char canon2[16], sec_c = (char) (GET_SECTOR(q) + 47), wk[3] = { (char) (GET_WALK1(q) + 64), (char) (GET_WALK2(q) + 64), 0 };
               gb->render(fp, canon2);
               int s4[PC_PAT_MAX_NAMES], e4[PC_PAT_MAX_NAMES];
               CHECK(pc_parts_match(pp, canon2, s4, e4) == 1);
               CHECK(e4[2] - s4[2] == 1 && canon2[s4[2]] == sec_c);
               CHECK(e4[3] - s4[3] == 2 && strncmp(canon2 + s4[3], wk, 2) == 0);
               CHECK(strncmp(canon2 + s4[0], areas[GET_AREA(q) - 1], strlen(areas[GET_AREA(q) - 1])) == 0);
            }
      }
   }
   printf("  codes the format accepts, all split exactly as its fields say: %ld (%ld of them with an inward code)\n", accepted_by_format, inward_tested);
   printf("  strings the format refuses: %ld, of which the pattern also accepts %ld (it is looser, which is fine: it only splits valid codes)\n",
          tested_negative, accepted_by_pattern_only);
   printf("\n%ld checks, %d failures\n", checks, failures);
   return failures ? 1 : 0;
}
