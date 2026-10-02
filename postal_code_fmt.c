#include <string.h>

#include "postal_code_fmt.h"

extern const pc_encoder pc_us_encoder;
extern const pc_encoder pc_ca_encoder;
extern const pc_encoder pc_fr_encoder;
extern const pc_encoder pc_br_encoder;
extern const pc_encoder pc_cz_encoder;
extern const pc_encoder pc_lu_encoder;
extern const pc_encoder pc_gb_encoder;
extern const pc_encoder pc_ie_encoder;

const pc_encoder * const pc_formats[PC_FMT_MAX] = {
   [PC_FMT_US] = &pc_us_encoder,
   [PC_FMT_CA] = &pc_ca_encoder,
   [PC_FMT_FR] = &pc_fr_encoder,
   [PC_FMT_BR] = &pc_br_encoder,
   [PC_FMT_CZ] = &pc_cz_encoder,
   [PC_FMT_LU] = &pc_lu_encoder,
   [PC_FMT_GB] = &pc_gb_encoder,
   [PC_FMT_IE] = &pc_ie_encoder,
};

pc_format pc_format_by_name (const char *name) {
   if (!name) return PC_FMT_UNKNOWN;
   for (pc_format fmt = 1; fmt < PC_FMT_MAX; fmt++) {
      if (pc_formats[fmt] && strcmp(pc_formats[fmt]->name, name) == 0) {
         return fmt;
      }
   }
   return PC_FMT_UNKNOWN;
}
