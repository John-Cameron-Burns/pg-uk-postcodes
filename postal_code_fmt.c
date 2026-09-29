#include "postal_code_fmt.h"

#define N_ELEMS(arr) (sizeof(arr) / sizeof((arr)[0]))

extern const pc_encoder pc_us_encoder;
extern const pc_encoder pc_ca_encoder;
extern const pc_encoder pc_fr_encoder;
extern const pc_encoder pc_br_encoder;
extern const pc_encoder pc_cz_encoder;
extern const pc_encoder pc_lu_encoder;

const pc_encoder * const pc_formats[PC_FMT_MAX] = {
   [PC_FMT_US] = &pc_us_encoder,
   [PC_FMT_CA] = &pc_ca_encoder,
   [PC_FMT_FR] = &pc_fr_encoder,
   [PC_FMT_BR] = &pc_br_encoder,
   [PC_FMT_CZ] = &pc_cz_encoder,
   [PC_FMT_LU] = &pc_lu_encoder,
};

// Alphabetical by ISO code purely for human readability here --
// lookup is linear (same convention as postcode_parse()'s area
// lookup in areas.h; this table won't get large enough to need
// better than that any time soon).
const pc_country_format pc_country_formats[] = {
   { .iso2 = {'B', 'R'}, .format = PC_FMT_BR },
   { .iso2 = {'C', 'A'}, .format = PC_FMT_CA },
   { .iso2 = {'C', 'Z'}, .format = PC_FMT_CZ },
   { .iso2 = {'F', 'R'}, .format = PC_FMT_FR },
   { .iso2 = {'L', 'U'}, .format = PC_FMT_LU },
   { .iso2 = {'U', 'S'}, .format = PC_FMT_US },
};
const size_t pc_country_formats_count = N_ELEMS(pc_country_formats);

pc_format pc_format_for_country (const char iso2[2]) {
   for (size_t i = 0; i < pc_country_formats_count; i++) {
      if (pc_country_formats[i].iso2[0] == iso2[0] &&
          pc_country_formats[i].iso2[1] == iso2[1]) {
         return pc_country_formats[i].format;
      }
   }
   return PC_FMT_UNKNOWN;
}
