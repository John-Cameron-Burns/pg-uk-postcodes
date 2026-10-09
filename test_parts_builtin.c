// The part names given to the built-in patterns, checked for ambiguity. No Postgres needed:
//
//   (run from the source directory: it reads postcode--2.0.1--2.1.0.sql)
//   cc -std=c99 -DEXTVERSION=test -o test_parts_builtin test_parts_builtin.c postal_code_pattern.c && ./test_parts_builtin
//
// Every UPDATE in the upgrade script that names a built-in pattern is compiled and its parts checked: no code may be
// splittable into its parts in more than one way, and the check must be exact (not a sample). That it denotes the
// same codes as before is checked by the extension itself when the UPDATE runs (the permanence trigger), and by the
// regression test. This is kept out of the regression suite because the exhaustive checks take a few seconds.

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "postal_code_pattern.h"

static int failures = 0;
static long checks = 0;
#define CHECK(cond) do { checks++; if (!(cond)) { if (failures < 20) printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

static void *xalloc (size_t n) { return malloc(n); }

int main (void) {
   FILE *f = fopen("postcode--2.0.1--2.1.0.sql", "r");
   if (!f) { printf("cannot read postcode--2.0.1--2.1.0.sql (run from the source directory)\n"); return 1; }
   char *buf = malloc(1 << 20);
   size_t n = fread(buf, 1, (1 << 20) - 1, f);
   buf[n] = '\0';
   fclose(f);

   int count = 0;
   double slowest = 0;
   char slowest_cc[3] = "";
   const char *p = buf;
   while ((p = strstr(p, "UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$")) != NULL) {
      p += strlen("UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$");
      const char *e = strstr(p, "$p$)");
      const char *w = strstr(e, "iso2 = '");
      char re[2048], cc[3], err[200], msg[300];
      size_t len = (size_t) (e - p);
      if (!e || !w || len >= sizeof re) { printf("cannot read an UPDATE\n"); return 1; }
      memcpy(re, p, len); re[len] = '\0';
      cc[0] = w[8]; cc[1] = w[9]; cc[2] = '\0';
      // the SQL function hands the regular expression between its slashes to the engine
      CHECK(re[0] == '/' && re[len - 1] == '/');
      re[len - 1] = '\0';

      pc_parts *parts = pc_parts_compile(re + 1, xalloc, err, sizeof err);
      pc_pattern *pat = pc_pattern_compile(re + 1, xalloc, err, sizeof err);
      CHECK(parts != NULL && pat != NULL);
      if (!parts || !pat) { printf("  %s: %s\n", cc, err); continue; }
      CHECK(pc_parts_count(parts) >= 2 || strcmp(cc, "AR") == 0);
      clock_t t0 = clock();
      int r = pc_parts_check(parts, pat, msg, sizeof msg);
      double secs = (double) (clock() - t0) / CLOCKS_PER_SEC;
      if (secs > slowest) { slowest = secs; strcpy(slowest_cc, cc); }
      if (r != PC_CHECK_UNAMBIGUOUS) printf("  %s: check result %d (%s) for %s\n", cc, r, msg, re);
      CHECK(r == PC_CHECK_UNAMBIGUOUS);                                   // exact, and no code splits two ways
      count++;
      p = e;
   }
   printf("%d built-in patterns with named parts, all unambiguous (slowest check %.2f s: %s)\n", count, slowest, slowest_cc);
   CHECK(count == 29);
   printf("\n%ld checks, %d failures\n", checks, failures);
   return failures ? 1 : 0;
}
