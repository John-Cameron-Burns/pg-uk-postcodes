// Reads a compiled format's parts pattern out of the upgrade script that ships it, so the tests check exactly
// what is installed:   ('GB', $p$...$p$),
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int load_parts_pattern (const char *format, char *out, size_t outlen) {
   FILE *f = fopen("postcode--2.0.1--2.1.0.sql", "r");
   if (!f) return 0;
   char key[16], *buf = malloc(1 << 20);
   size_t n = fread(buf, 1, (1 << 20) - 1, f);
   buf[n] = '\0';
   fclose(f);
   snprintf(key, sizeof key, "('%s', $p$", format);
   char *p = strstr(buf, key);
   int ok = 0;
   if (p) {
      p += strlen(key);
      char *e = strstr(p, "$p$)");
      if (e && (size_t) (e - p) < outlen) { memcpy(out, p, (size_t) (e - p)); out[e - p] = '\0'; ok = 1; }
   }
   free(buf);
   return ok;
}
