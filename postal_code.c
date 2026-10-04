#include <string.h>
#include <stdio.h>

#include <postgres.h>
#if PG_VERSION_NUM >= 160000
#include <varatt.h>      // split out of postgres.h in PostgreSQL 16
#endif
#include <fmgr.h>
#include <utils/builtins.h>
#include <libpq/pqformat.h>
#include <access/htup_details.h>
#include <catalog/namespace.h>
#include <catalog/pg_type.h>
#include <utils/array.h>
#include <commands/trigger.h>
#include <nodes/makefuncs.h>
#include <nodes/nodeFuncs.h>
#include <nodes/pathnodes.h>
#include <nodes/supportnodes.h>
#include <utils/inval.h>
#include <utils/lsyscache.h>
#include <utils/rangetypes.h>
#include <utils/rel.h>
#include <utils/typcache.h>

// PG_MODULE_MAGIC lives in postcode.c -- exactly one per shared
// library, and postal_code.o/postcode.o link into the same
// postcode.so (one package, both types; see this repo's Makefile).

#include "postal_code.h"
#include "postal_code_fmt.h"
#include <mb/pg_wchar.h>

#include "postal_code_country.h"
#include "postal_code_tpl.h"

#ifndef EXTVERSION
#error  EXTVERSION is not defined
#endif

#define STR(macro) QUOTE(macro)
#define QUOTE(name) #name

// postal_code is logically a *uint64* -- the country field can set
// bit 63 (e.g. any country from roughly Q onwards), so treated as a
// signed int64 it can be negative. Int64GetDatum()/DatumGetInt64()
// don't care either way -- on a 64-bit Datum they just move the
// bit pattern in and out unchanged -- but every comparison in this
// file operates on the `postal_code` (uint64_t) value, never on the
// int64 Datum representation directly, so sign never enters into
// it. Rely on this same convention in any new function added here.
#define PG_RETURN_POSTAL_CODE(p) return Int64GetDatum((int64) (p))
#define PG_GETARG_POSTAL_CODE(n) ((postal_code) DatumGetInt64(PG_GETARG_DATUM(n)))

Datum postal_code_in       (PG_FUNCTION_ARGS);
Datum postal_code_out      (PG_FUNCTION_ARGS);
Datum postal_code_recv     (PG_FUNCTION_ARGS);
Datum postal_code_send     (PG_FUNCTION_ARGS);
Datum postal_code_cmp      (PG_FUNCTION_ARGS);
Datum postal_code_eq       (PG_FUNCTION_ARGS);
Datum postal_code_ne       (PG_FUNCTION_ARGS);
Datum postal_code_lt       (PG_FUNCTION_ARGS);
Datum postal_code_gt       (PG_FUNCTION_ARGS);
Datum postal_code_lte      (PG_FUNCTION_ARGS);
Datum postal_code_gte      (PG_FUNCTION_ARGS);
Datum postal_code_from_parts (PG_FUNCTION_ARGS);
Datum postal_code_lenient  (PG_FUNCTION_ARGS);
Datum postal_code_lower_bound (PG_FUNCTION_ARGS);
Datum postal_code_upper_bound (PG_FUNCTION_ARGS);
Datum postal_code_prefix (PG_FUNCTION_ARGS);
Datum postal_code_prefix_lenient (PG_FUNCTION_ARGS);
Datum postal_code_outcode (PG_FUNCTION_ARGS);
Datum postal_code_prefix_support (PG_FUNCTION_ARGS);
Datum postal_code_partial (PG_FUNCTION_ARGS);
Datum postal_code_not_partial (PG_FUNCTION_ARGS);
Datum postal_code_partial_support (PG_FUNCTION_ARGS);
Datum postal_code_typmod_in (PG_FUNCTION_ARGS);
Datum postal_code_typmod_out (PG_FUNCTION_ARGS);
Datum postal_code_enforce (PG_FUNCTION_ARGS);
Datum postal_code_formats_changed (PG_FUNCTION_ARGS);
Datum postal_code_template_check (PG_FUNCTION_ARGS);
Datum postal_code_lenient_text (PG_FUNCTION_ARGS);
Datum postal_code_country  (PG_FUNCTION_ARGS);

// Why a country code failed to resolve, so the strict constructors can
// raise a specific error and to_postal_code() can decide which of them
// are "bad input" (NULL) and which are a configuration fault (still raise).
typedef enum { LC_OK, LC_BAD_SHAPE, LC_NO_ASSIGNMENT, LC_FORMAT_MISSING } lc_result;

// Resolves cc (any case) to a format via the SQL postal_code_country_formats
// table (postal_code_country.c) -- not anything compiled in; see
// add_country_format(). On LC_FORMAT_MISSING *format_name is the assigned
// name this build doesn't have.
static pc_format lookup_country_try (const char *cc, size_t len, char out_iso2[2],
                                     lc_result *why, char **format_name) {
   *why = LC_OK;
   *format_name = NULL;

   if (len != 2) { *why = LC_BAD_SHAPE; return PC_FMT_UNKNOWN; }

   char c0 = cc[0], c1 = cc[1];
   if (c0 >= 'a' && c0 <= 'z') c0 = (char) (c0 - 32);
   if (c1 >= 'a' && c1 <= 'z') c1 = (char) (c1 - 32);
   if (c0 < 'A' || c0 > 'Z' || c1 < 'A' || c1 > 'Z') { *why = LC_BAD_SHAPE; return PC_FMT_UNKNOWN; }

   out_iso2[0] = c0;
   out_iso2[1] = c1;

   int slot;
   *format_name = pc_lookup_country_format(out_iso2, &slot);
   if (!*format_name) { *why = LC_NO_ASSIGNMENT; return PC_FMT_UNKNOWN; }

   pc_format fmt = slot >= 0 ? (pc_format) slot : pc_format_by_name(*format_name);
   if (fmt == PC_FMT_UNKNOWN) *why = LC_FORMAT_MISSING;
   return fmt;
}

static void lookup_country_raise (lc_result why, const char *cc, size_t len,
                                  const char iso2[2], const char *format_name) {
   switch (why) {
   case LC_BAD_SHAPE:
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("\"%.*s\" is not a two-letter country code"), (int) len, cc)));
   case LC_NO_ASSIGNMENT:
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("\"%c%c\" is not a supported country code"), iso2[0], iso2[1]),
                      errhint(_("see postal_code_country_formats, or add one with add_country_format()"))));
   case LC_FORMAT_MISSING:
      ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                      errmsg (_("country \"%c%c\" is assigned to format \"%s\", "
                                "which this build of postal_code does not have"),
                              iso2[0], iso2[1], format_name)));
   case LC_OK:
      break;
   }
}

// ---- format dispatch ----------------------------------------------------------
// A format tag is either a compiled encoder (postal_code_fmt.c) or a slot in
// the postal_code_templates table (postal_code_template.h). Everything below
// goes through these so it need not care which. A tag that is neither (a
// slot the table has no row for, or garbage in a binary value) does not
// resolve.
typedef struct {
   const pc_encoder *enc;   // NULL for a template
   pc_template       tpl;
} fmt_impl;

static bool fmt_resolve (pc_format fmt, fmt_impl *f) {
   f->enc = NULL;
   if (fmt > PC_FMT_UNKNOWN && fmt < PC_FMT_MAX && pc_formats[fmt]) { f->enc = pc_formats[fmt]; return true; }
   return pc_template_for_slot((int) fmt, &f->tpl);
}

// A format that has to resolve because a country was just assigned to it:
// failing is a configuration fault.
static void fmt_resolve_or_raise (pc_format fmt, fmt_impl *f) {
   if (!fmt_resolve(fmt, f))
      ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
                      errmsg (_("postal code format %d is not defined"), (int) fmt),
                      errhint(_("a template slot needs a row in postal_code_templates"))));
}

static const char *fmt_describe (const fmt_impl *f) {
   return f->enc ? f->enc->name : psprintf("template \"%s\"", f->tpl.spec);
}
static size_t fmt_max_text_len (const fmt_impl *f) { return f->enc ? f->enc->max_text_len : (size_t) f->tpl.nitems; }

static inline bool ascii_alpha (char c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'); }
static inline char ascii_upper (char c) { return (c >= 'a' && c <= 'z') ? (char) (c - 32) : c; }

// ---- obvious variants ---------------------------------------------------------
// Real data writes the same code in slightly different ways. Whatever a format
// accepts as written is taken exactly as written; only when that fails are
// these variants tried, in order, and the first that parses wins:
//   - with the country's own letters dropped from the front ("MH96960",
//     "AI 2640" -> the code, since the country is already known; "IM1 1AA" is
//     tried as written first, so Jersey, Guernsey and the Isle of Man are safe);
//   - each of those with spaces and hyphens swapped ("1050 010" for "1050-010",
//     "L 1820" for "L-1820", "SW1A-1AA");
//   - or with the spaces dropped altogether ("06 830", "19 801", "K1A0B1"), or
//     the dots ("06.026-170", the way a CEP is often punctuated).
// They only ever re-spell the same characters, so a variant can't turn
// something that is not a code into one, only recognise a spelling that is.
#define MAX_FORMS 14

static int variant_forms (const char *text, const char iso2[2], const char *forms[MAX_FORMS]) {
   int n = 0;
   const char *bases[2] = { text, NULL };
   char a = text[0], b = a ? text[1] : '\0';
   if (ascii_upper(a) == iso2[0] && ascii_upper(b) == iso2[1]) {
      const char *rest = text + 2;
      if (*rest == ' ' || *rest == '-') rest++;
      if (*rest) bases[1] = rest;
   }

   for (int i = 0; i < 2; i++) {
      if (!bases[i]) continue;
      char *spaced = pstrdup(bases[i]), *hyphened = pstrdup(bases[i]);
      char *packed = palloc(strlen(bases[i]) + 1);
      size_t k = 0;
      for (const char *c = bases[i]; *c; c++) if (*c != ' ') packed[k++] = *c;
      packed[k] = '\0';
      for (char *c = hyphened; *c; c++) if (*c == ' ') *c = '-';
      for (char *c = spaced; *c; c++) if (*c == '-') *c = ' ';

      char *dotless = palloc(strlen(bases[i]) + 1);
      k = 0;
      for (const char *c = bases[i]; *c; c++) if (*c != '.') dotless[k++] = *c;
      dotless[k] = '\0';
      const char *cand[5] = { bases[i], hyphened, spaced, packed, dotless };
      for (int j = 0; j < 5; j++) {
         bool seen = false;
         for (int m = 0; m < n; m++) if (strcmp(forms[m], cand[j]) == 0) seen = true;
         if (!seen && n < MAX_FORMS) forms[n++] = cand[j];
      }
   }
   return n;
}

// Text may carry the country's own letters in front ("VG1110") when the
// template says that is how the country writes its codes (a leading CC);
// they are checked here and dropped, since the country is already known.
static bool fmt_parse_one (const fmt_impl *f, const char iso2[2], const char *text, uint64_t *payload) {
   if (f->enc) return f->enc->parse(text, false, payload) && f->enc->valid(*payload);
   return pc_template_parse(&f->tpl, pc_template_skip_cc(&f->tpl, iso2, text), payload);
}
static bool fmt_parse_valid (const fmt_impl *f, const char iso2[2], const char *text, uint64_t *payload) {
   const char *forms[MAX_FORMS];
   int n = variant_forms(text, iso2, forms);
   for (int i = 0; i < n; i++)
      if (fmt_parse_one(f, iso2, forms[i], payload)) return true;
   return false;
}
static int fmt_render (const fmt_impl *f, uint64_t payload, char *buf) {
   return f->enc ? f->enc->render(payload, buf) : pc_template_render(&f->tpl, payload, buf);
}
static bool fmt_valid (const fmt_impl *f, uint64_t payload) {
   return f->enc ? f->enc->valid(payload) : pc_template_valid(&f->tpl, payload);
}
static bool fmt_has_range (const fmt_impl *f) { return f->enc ? f->enc->range != NULL : true; }
static bool fmt_range_one (const fmt_impl *f, const char iso2[2], const char *frag, uint64_t *lo, uint64_t *hi, bool *unbounded) {
   return f->enc ? f->enc->range(frag, lo, hi, unbounded)
                 : pc_template_range(&f->tpl, pc_template_skip_cc(&f->tpl, iso2, frag), lo, hi, unbounded);
}
static bool fmt_range (const fmt_impl *f, const char iso2[2], const char *frag, uint64_t *lo, uint64_t *hi, bool *unbounded) {
   const char *forms[MAX_FORMS];
   int n = variant_forms(frag, iso2, forms);
   for (int i = 0; i < n; i++)
      if (fmt_range_one(f, iso2, forms[i], lo, hi, unbounded)) return true;
   return false;
}
static bool fmt_has_outcode (const fmt_impl *f) { return f->enc ? f->enc->outcode != NULL : f->tpl.has_tail; }
static uint64_t fmt_outcode (const fmt_impl *f, uint64_t payload) {
   return f->enc ? f->enc->outcode(payload) : pc_template_outcode(&f->tpl, payload);
}

// Shared by postal_code_in() and postal_code_from_parts(): always either
// raises or returns a real, implemented format; never PC_FMT_UNKNOWN, so
// callers don't need their own failure check.
static pc_format lookup_country (const char *cc, size_t len, char out_iso2[2]) {
   lc_result why;
   char *format_name;
   pc_format fmt = lookup_country_try(cc, len, out_iso2, &why, &format_name);
   if (why != LC_OK) lookup_country_raise(why, cc, len, out_iso2, format_name);
   return fmt;
}


// A column declared postal_code('US') carries the country as its type modifier
// (typmod): the packed ISO letters, so 0..825, with -1 meaning "not locked".
// Checked wherever a value enters a column: text input (which then also
// accepts the national code with no "US-" in front), binary receive, and the
// length-coercion cast PostgreSQL applies on INSERT/UPDATE/::postal_code('US').
static void raise_lock_mismatch (const char *have, const char *want) {
   ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                   errmsg (_("postal code of country \"%s\" does not match the column's country \"%s\""), have, want),
                   errhint(_("the column is declared postal_code('%s')"), want)));
}

static void check_lock (postal_code pc, int32 typmod) {
   if (typmod < 0 || (int32) GET_COUNTRY(pc) == typmod) return;
   char have[2], want[2];
   pc_unpack_country((uint16_t) GET_COUNTRY(pc), have);
   pc_unpack_country((uint16_t) typmod, want);
   char h[3] = { have[0], have[1], 0 }, w[3] = { want[0], want[1], 0 };
   raise_lock_mismatch(h, w);
}

// Builds a postal_code from an already-identified country/format
// and a national-part payload -- the one place country/format
// packing happens, so postal_code_in() and postal_code_from_parts()
// can't drift apart on how they assemble a value.
static inline postal_code pc_assemble (const char iso2[2], pc_format fmt, uint64_t payload) {
   postal_code pc = 0;
   SET_COUNTRY(pc, pc_pack_country(iso2[0], iso2[1]));
   SET_FORMAT(pc, fmt);
   SET_PAYLOAD(pc, payload);
   return pc;
}


// Real feeds are untidy in ways this can fix without guessing: spacing, and
// characters that are another script's spelling of the same thing. Trims the
// ends, collapses any run of whitespace to one space, drops a space next to a
// hyphen, and (in a UTF-8 or SQL_ASCII database) re-spells:
//   - decimal digits of other scripts as 0-9 (Persian "۱۲۳", Arabic-Indic,
//     Bengali, Burmese, Devanagari, Thai ... and full-width);
//   - the Unicode hyphens and minus signs (U+2010..2015, U+2212, ...) as "-";
//   - no-break and other Unicode spaces as a space; full-width letters as ASCII; Malta's Ċ Ġ Ħ Ż as C G H Z;
//   - and drops zero-width characters and Japan's postal mark 〒 (U+3012).
// So " us - 90210 ", "L - 2226", "SW1A  1AA", "〒050−0083" and "۱۲۳۴۵" mean what
// they obviously mean. Nothing else is touched, so what is accepted is still
// exactly the format's own grammar. Returns a copy.
static const uint32_t digit_zeros[] = {
   0x0660, 0x06F0, 0x07C0, 0x0966, 0x09E6, 0x0A66, 0x0AE6, 0x0B66, 0x0BE6, 0x0C66, 0x0CE6, 0x0D66,
   0x0DE6, 0x0E50, 0x0ED0, 0x0F20, 0x1040, 0x1090, 0x17E0, 0x1810, 0x1946, 0x19D0, 0x1A80, 0x1A90,
   0x1B50, 0x1BB0, 0x1C40, 0x1C50, 0xA620, 0xA8D0, 0xA900, 0xA9D0, 0xA9F0, 0xAA50, 0xABF0, 0xFF10,
};

// What a non-ASCII character stands for: a digit or letter or '-' or ' ' (returned), 0 for "drop it",
// or -1 for "leave it alone".
static int respell (uint32_t cp) {
   for (size_t i = 0; i < sizeof digit_zeros / sizeof *digit_zeros; i++)
      if (cp >= digit_zeros[i] && cp < digit_zeros[i] + 10) return (int) ('0' + (cp - digit_zeros[i]));
   if ((cp >= 0x2010 && cp <= 0x2015) || cp == 0x2212 || cp == 0xFE58 || cp == 0xFE63 || cp == 0xFF0D || cp == 0x2043) return '-';
   if (cp == 0x00A0 || cp == 0x1680 || (cp >= 0x2000 && cp <= 0x200A) || cp == 0x202F || cp == 0x205F || cp == 0x3000) return ' ';
   // Malta's four extra letters: its postcodes are officially the ASCII letters (ZTN 3000), mapped as
   // Żejtun, Mellieħa ... and no other country's postcode contains them
   if (cp == 0x010A || cp == 0x0120 || cp == 0x0126 || cp == 0x017B) return cp == 0x010A ? 'C' : cp == 0x0120 ? 'G' : cp == 0x0126 ? 'H' : 'Z';
   if (cp == 0x010B || cp == 0x0121 || cp == 0x0127 || cp == 0x017C) return cp == 0x010B ? 'c' : cp == 0x0121 ? 'g' : cp == 0x0127 ? 'h' : 'z';
   if (cp >= 0xFF21 && cp <= 0xFF3A) return (int) ('A' + (cp - 0xFF21));
   if (cp >= 0xFF41 && cp <= 0xFF5A) return (int) ('a' + (cp - 0xFF41));
   if ((cp >= 0x200B && cp <= 0x200F) || cp == 0xFEFF || cp == 0x2060 || cp == 0x3012) return 0;
   return -1;
}

static char *tidy (const char *s) {
   int enc = GetDatabaseEncoding();
   bool unicode = enc == PG_UTF8 || enc == PG_SQL_ASCII;
   char *out = palloc(strlen(s) + 1);     // a respelling is never longer than what it replaces
   size_t n = 0;
   bool space = false;
   while (*s) {
      unsigned char b = (unsigned char) *s;
      int c = b;
      size_t len = 1;
      if (b >= 0xC2 && unicode) {                 // a UTF-8 lead byte: decode it if it is well formed
         len = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : 2;
         uint32_t cp = b & (0xFF >> (len + 1));
         size_t k = 1;
         for (; k < len && ((unsigned char) s[k] & 0xC0) == 0x80; k++) cp = (cp << 6) | ((unsigned char) s[k] & 0x3F);
         if (k == len) {
            int r = respell(cp);
            if (r == 0) { s += len; continue; }
            if (r > 0) c = r; else len = 1;
         } else len = 1;
      }
      if (len > 1 || c < 0x80) {                   // a respelled or plain ASCII character
         if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { space = true; s += len; continue; }
         if (space && n > 0 && c != '-' && out[n - 1] != '-') out[n++] = ' ';
         space = false;
         out[n++] = (char) c;
         s += len;
      } else {                                      // any other byte is passed through
         if (space && n > 0 && out[n - 1] != '-') out[n++] = ' ';
         space = false;
         out[n++] = *s++;
      }
   }
   out[n] = '\0';
   return out;
}

PG_FUNCTION_INFO_V1(postal_code_in);

Datum postal_code_in (PG_FUNCTION_ARGS) {
   char *str = tidy(PG_GETARG_CSTRING(0));
   int32 typmod = PG_GETARG_INT32(2);       // -1, or the country the column is locked to

   char locked[3] = { 0, 0, 0 };
   if (typmod >= 0) {
      char l[2];
      pc_unpack_country((uint16_t) typmod, l);
      locked[0] = l[0]; locked[1] = l[1];
   }

   // UPU form: ISO 3166-1 alpha-2, a hyphen, then the national code
   // ("US-90210-1234"). The country is always exactly two characters, so
   // the FIRST hyphen is unambiguously the delimiter even for national codes
   // that contain hyphens of their own (US ZIP+4, BR CEP).
   bool prefixed = ascii_alpha(str[0]) && ascii_alpha(str[1]) && str[2] == '-';

   char country[3];
   const char *national;
   if (prefixed) {
      country[0] = ascii_upper(str[0]);
      country[1] = ascii_upper(str[1]);
      country[2] = '\0';
      national = str + 3;
      if (locked[0] && strcmp(country, locked) != 0) raise_lock_mismatch(country, locked);
   } else if (locked[0]) {
      // a locked column already knows its country, so the bare national
      // code is enough: '90210' into a postal_code('US') column
      strcpy(country, locked);
      national = str;
   } else {
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("postal_code requires a two-letter country prefix, e.g. \"US-90210\"")),
                      errhint(_("got \"%s\""), str)));
   }

   // "CC-~" is the end-of-country bound (see PC_FMT_END): not a postcode,
   // only ever the upper end of a range. It must be written exactly, so an
   // empty or missing national code ("US-") is still an error rather than
   // quietly becoming a marker.
   if (prefixed && strcmp(national, "~") == 0)
      PG_RETURN_POSTAL_CODE(pc_assemble(country, (pc_format) PC_FMT_END, 0));

   char iso2[2];
   pc_format fmt = lookup_country(country, 2, iso2);
   fmt_impl f;
   fmt_resolve_or_raise(fmt, &f);

   uint64_t payload;
   if (! fmt_parse_valid(&f, iso2, national, &payload))
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("cannot parse \"%s\" as a %s postal code"),
                              national, fmt_describe(&f))));

   PG_RETURN_POSTAL_CODE(pc_assemble(iso2, fmt, payload));
}


PG_FUNCTION_INFO_V1(postal_code_out);

Datum postal_code_out (PG_FUNCTION_ARGS) {
   postal_code pc = PG_GETARG_POSTAL_CODE(0);

   pc_format fmt = (pc_format) GET_FORMAT(pc);

   if (fmt == PC_FMT_END && GET_PAYLOAD(pc) == 0) {      // the end-of-country bound
      char iso2e[2];
      pc_unpack_country((uint16_t) GET_COUNTRY(pc), iso2e);
      char *end = palloc(5);
      sprintf(end, "%c%c-~", iso2e[0], iso2e[1]);
      PG_RETURN_CSTRING(end);
   }

   fmt_impl f;
   if (!fmt_resolve(fmt, &f))
      ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
                      errmsg (_("cannot render corrupted binary data to text"))));

   char iso2[2];
   pc_unpack_country((uint16_t) GET_COUNTRY(pc), iso2);

   char *out = palloc(3 + fmt_max_text_len(&f) + 1); // "CC-" + code + NUL
   int n = sprintf(out, "%c%c-", iso2[0], iso2[1]);
   fmt_render(&f, GET_PAYLOAD(pc), out + n);

   PG_RETURN_CSTRING(out);
}


PG_FUNCTION_INFO_V1(postal_code_recv);

Datum postal_code_recv (PG_FUNCTION_ARGS) {
   postal_code pc = (postal_code) pq_getmsgint64((StringInfo) PG_GETARG_POINTER(0));

   pc_format fmt = (pc_format) GET_FORMAT(pc);
   uint16_t country = (uint16_t) GET_COUNTRY(pc);
   bool end_bound = fmt == PC_FMT_END && GET_PAYLOAD(pc) == 0 &&
                    (country >> PC_LETTER_BITS) < 26 && (country & ((1 << PC_LETTER_BITS) - 1)) < 26;
   fmt_impl f;
   if (!end_bound &&
       (!fmt_resolve(fmt, &f) || ! fmt_valid(&f, GET_PAYLOAD(pc))))
      ereport(ERROR, (errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
                      errmsg (_("received binary data is invalid for type postal_code")),
                      errhint(_("server binary format version is %s"), STR(EXTVERSION))));

   check_lock(pc, PG_GETARG_INT32(2));
   PG_RETURN_POSTAL_CODE(pc);
}


PG_FUNCTION_INFO_V1(postal_code_send);

Datum postal_code_send (PG_FUNCTION_ARGS) {
   StringInfoData buf;
   pq_begintypsend(&buf);
   pq_sendint64(&buf, (int64) PG_GETARG_POSTAL_CODE(0));
   PG_RETURN_BYTEA_P(pq_endtypsend(&buf));
}


PG_FUNCTION_INFO_V1(postal_code_cmp);

Datum postal_code_cmp (PG_FUNCTION_ARGS) {
   postal_code a = PG_GETARG_POSTAL_CODE(0),
               b = PG_GETARG_POSTAL_CODE(1);

   if (a == b) PG_RETURN_INT32( 0);
   if (a >  b) PG_RETURN_INT32( 1);
   else        PG_RETURN_INT32(-1);
}


PG_FUNCTION_INFO_V1(postal_code_eq);
Datum postal_code_eq (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_POSTAL_CODE(0) == PG_GETARG_POSTAL_CODE(1));
}

PG_FUNCTION_INFO_V1(postal_code_ne);
Datum postal_code_ne (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_POSTAL_CODE(0) != PG_GETARG_POSTAL_CODE(1));
}

PG_FUNCTION_INFO_V1(postal_code_lt);
Datum postal_code_lt (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_POSTAL_CODE(0) < PG_GETARG_POSTAL_CODE(1));
}

PG_FUNCTION_INFO_V1(postal_code_gt);
Datum postal_code_gt (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_POSTAL_CODE(0) > PG_GETARG_POSTAL_CODE(1));
}

PG_FUNCTION_INFO_V1(postal_code_lte);
Datum postal_code_lte (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_POSTAL_CODE(0) <= PG_GETARG_POSTAL_CODE(1));
}

PG_FUNCTION_INFO_V1(postal_code_gte);
Datum postal_code_gte (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_POSTAL_CODE(0) >= PG_GETARG_POSTAL_CODE(1));
}


// ---- postal_code(postcode, cc) -------------------------------------------
// The postcode may carry its own country as a "CC-" prefix ("US-90210") and
// the country may also be given separately. Rules:
//   - prefix and cc both present: they must agree (case-insensitively), else
//     an error -- two sources of truth that differ are a data bug to surface
//   - prefix only (cc NULL): the prefix is used
//   - cc only (no prefix): cc is the country and the whole text is the national code
//   - neither: an error (strict) / NULL (lenient) -- there is nothing to go on
// "Has a prefix" means exactly two letters then a hyphen. No national format
// starts that way (LU's "L-1311" has one letter), so it is unambiguous.

typedef enum { SC_OK, SC_NO_COUNTRY, SC_BAD_CC, SC_MISMATCH } sc_result;

static sc_result split_country (const char *postcode, const char *cc, char country[3], const char **national) {
   char want[3] = { 0, 0, 0 };
   if (cc) {
      if (strlen(cc) != 2 || !ascii_alpha(cc[0]) || !ascii_alpha(cc[1])) return SC_BAD_CC;
      want[0] = ascii_upper(cc[0]);
      want[1] = ascii_upper(cc[1]);
   }

   if (ascii_alpha(postcode[0]) && ascii_alpha(postcode[1]) && postcode[2] == '-') {
      country[0] = ascii_upper(postcode[0]);
      country[1] = ascii_upper(postcode[1]);
      country[2] = '\0';
      if (cc && strcmp(country, want) != 0) return SC_MISMATCH;
      *national = postcode + 3;
      return SC_OK;
   }

   if (!cc) return SC_NO_COUNTRY;
   strcpy(country, want);
   *national = postcode;
   return SC_OK;
}

// postal_code(postcode, cc), analogous to PostGIS's ST_GeomFromText(wkt,
// srid): for callers that have the national code and the country as
// separate values, or a "CC-code" string that may or may not also have a
// separate country column to cross-check against. Unlike ST_SetSRID(),
// there is no cheap "retag an existing value" counterpart -- that would
// silently corrupt the payload for any two formats that aren't
// bit-compatible. NULL postcode gives NULL.
PG_FUNCTION_INFO_V1(postal_code_from_parts);

Datum postal_code_from_parts (PG_FUNCTION_ARGS) {
   if (PG_ARGISNULL(0)) PG_RETURN_NULL();

   char *postcode = tidy(text_to_cstring(PG_GETARG_TEXT_PP(0)));
   char *cc       = PG_ARGISNULL(1) ? NULL : tidy(text_to_cstring(PG_GETARG_TEXT_PP(1)));

   char country[3];
   const char *national;
   switch (split_country(postcode, cc, country, &national)) {
   case SC_BAD_CC:
      lookup_country_raise(LC_BAD_SHAPE, cc, strlen(cc), "??", NULL);
      break;
   case SC_MISMATCH:
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("country code \"%s\" does not match the \"%.2s-\" prefix of \"%s\""),
                              cc, postcode, postcode),
                      errhint(_("pass NULL as the country code to use the prefix, or drop the prefix"))));
      break;
   case SC_NO_COUNTRY:
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("\"%s\" has no country: no \"CC-\" prefix, and no country code was given"), postcode),
                      errhint(_("write it as \"US-90210\", or pass the country as the second argument"))));
      break;
   case SC_OK:
      break;
   }

   char iso2[2];
   pc_format fmt = lookup_country(country, 2, iso2);

   fmt_impl f;
   fmt_resolve_or_raise(fmt, &f);

   uint64_t payload;
   if (! fmt_parse_valid(&f, iso2, national, &payload))
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("cannot parse \"%s\" as a %s postal code"), national, fmt_describe(&f))));

   PG_RETURN_POSTAL_CODE(pc_assemble(iso2, fmt, payload));
}


// NULL-returning counterparts of the strict constructors, for loading feeds
// that contain rows which are not valid postcodes (the same role
// topostcode() plays for the UK type): anything that would make the strict
// form raise as bad INPUT -- no country, a country that disagrees with the
// prefix, a malformed or unassigned country, a national code that doesn't
// parse -- yields NULL instead of an error that aborts the whole
// COPY/INSERT. Strictness stays the default; this is opt-in by name. A
// country assigned to a format this build doesn't have is a configuration
// fault, not bad input, and still raises. Two forms, mirroring ::postal_code
// and postal_code(postcode, cc):
//   to_postal_code('FR-75054 CEDEX 01')   and   to_postal_code('75054 CEDEX 01', 'FR')
static bool lenient_build (const char *postcode, const char *cc, postal_code *out) {
   char country[3];
   const char *national;
   if (split_country(postcode, cc, country, &national) != SC_OK) return false;

   char iso2[2];
   lc_result why;
   char *format_name;
   pc_format fmt = lookup_country_try(country, 2, iso2, &why, &format_name);
   if (why == LC_BAD_SHAPE || why == LC_NO_ASSIGNMENT) return false;
   if (why != LC_OK) lookup_country_raise(why, country, 2, iso2, format_name);

   fmt_impl f;
   fmt_resolve_or_raise(fmt, &f);

   uint64_t payload;
   if (! fmt_parse_valid(&f, iso2, national, &payload)) return false;

   *out = pc_assemble(iso2, fmt, payload);
   return true;
}

PG_FUNCTION_INFO_V1(postal_code_lenient);

Datum postal_code_lenient (PG_FUNCTION_ARGS) {
   if (PG_ARGISNULL(0)) PG_RETURN_NULL();

   char *postcode = tidy(text_to_cstring(PG_GETARG_TEXT_PP(0)));
   char *cc       = PG_ARGISNULL(1) ? NULL : tidy(text_to_cstring(PG_GETARG_TEXT_PP(1)));

   postal_code pc;
   if (! lenient_build(postcode, cc, &pc)) PG_RETURN_NULL();
   PG_RETURN_POSTAL_CODE(pc);
}


PG_FUNCTION_INFO_V1(postal_code_lenient_text);

Datum postal_code_lenient_text (PG_FUNCTION_ARGS) {
   postal_code pc;
   if (! lenient_build(tidy(text_to_cstring(PG_GETARG_TEXT_PP(0))), NULL, &pc)) PG_RETURN_NULL();
   PG_RETURN_POSTAL_CODE(pc);
}


// Fragment -> [lo, hi) for partial match. "CC-" then a prefix of the national
// code, e.g. 'GB-LS24', 'FR-75', 'CA-K1A 0'. The per-format work is the
// encoder's range() hook (see pc_encoder in postal_code_fmt.h); this is only
// the shared "CC-fragment" plumbing. A fragment is not a value: 'FR-75' is a
// fragment but not a postcode, so these raise on text that isn't a fragment
// of the country's format, like the strict constructors do for bad values.
static pc_format fragment_range (const char *str, char iso2[2], uint64_t *lo, uint64_t *hi, bool *unbounded) {
   char *hyphen = strchr(str, '-');
   if (!hyphen || hyphen - str != 2)
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("a postal code fragment requires a two-letter country prefix, e.g. \"GB-LS24\"")),
                      errhint(_("got \"%s\""), str)));

   pc_format fmt = lookup_country(str, 2, iso2);

   fmt_impl f;
   fmt_resolve_or_raise(fmt, &f);

   if (!fmt_has_range(&f))
      ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                      errmsg (_("the %s postal code format does not support ranges"), fmt_describe(&f))));

   if (! fmt_range(&f, iso2, hyphen + 1, lo, hi, unbounded))
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("cannot parse \"%s\" as a fragment of a %s postal code"),
                              hyphen + 1, fmt_describe(&f))));
   return fmt;
}

// The smallest VALID value that starts with the fragment (for 'CA-K', the
// outcode 'CA-K0A'); included in the range.
PG_FUNCTION_INFO_V1(postal_code_lower_bound);

Datum postal_code_lower_bound (PG_FUNCTION_ARGS) {
   char iso2[2];
   uint64_t lo, hi;
   bool unbounded;
   pc_format fmt = fragment_range(tidy(text_to_cstring(PG_GETARG_TEXT_PP(0))), iso2, &lo, &hi, &unbounded);
   PG_RETURN_POSTAL_CODE(pc_assemble(iso2, fmt, lo));
}

// The smallest value past everything that starts with the fragment
// (excluded from the range): a real postcode wherever a successor exists,
// e.g. 'CA-K1A' -> 'CA-K1B'. Where there is none -- the fragment reaches the
// top of the country's space ('US-99', 'FR-9') -- the end-of-country bound
// 'US-~' (PC_FMT_END): it sorts after every value of that country and before
// the next, so `pc < upper_bound(...)` is right there too. (A range's own
// "no upper end" would be wrong: that is the end of the whole value space, and
// would run on into every later country.) It is a bound, never a postcode.
PG_FUNCTION_INFO_V1(postal_code_upper_bound);

Datum postal_code_upper_bound (PG_FUNCTION_ARGS) {
   char iso2[2];
   uint64_t lo, hi;
   bool unbounded;
   pc_format fmt = fragment_range(tidy(text_to_cstring(PG_GETARG_TEXT_PP(0))), iso2, &lo, &hi, &unbounded);
   if (unbounded) PG_RETURN_POSTAL_CODE(pc_assemble(iso2, (pc_format) PC_FMT_END, 0));
   PG_RETURN_POSTAL_CODE(pc_assemble(iso2, fmt, hi));
}


// Builds the [lo, hi) range of the given range type. Always bounded: the top
// of a country ends at its end-of-country bound, never at "no upper end".
static Datum build_prefix_range (Oid rngtypid, postal_code lo, postal_code hi) {
   TypeCacheEntry *typcache = lookup_type_cache(rngtypid, TYPECACHE_RANGE_INFO);
   if (typcache->rngelemtype == NULL)
      elog(ERROR, "type %u is not a range type", rngtypid);

   RangeBound l, u;
   l.val = Int64GetDatum((int64) lo);
   l.infinite = false; l.inclusive = true;  l.lower = true;
   u.val = Int64GetDatum((int64) hi);
   u.infinite = false; u.inclusive = false; u.lower = false;

#if PG_VERSION_NUM >= 160000
   return RangeTypePGetDatum(range_serialize(typcache, &l, &u, false, NULL));
#else
   return RangeTypePGetDatum(range_serialize(typcache, &l, &u, false));
#endif
}

// postal_prefix('GB-LS24') -> the range [GB-LS24, GB-LS25); 'US-99' ->
// [US-99000, US-~). This is what to filter on:
//
//     WHERE pc <@ postal_prefix('GB-LS24')
//
// Always bounded. At the top of a country the upper end is that country's
// end-of-country bound ('US-~'), NOT an absent upper end: a range's "no
// upper end" is the end of the whole value space, so [BR-99000,) would
// swallow CA, CZ, ... US. (Found by comparing every prefix in 148k real rows
// against a plain text group-by.)
PG_FUNCTION_INFO_V1(postal_code_prefix);

Datum postal_code_prefix (PG_FUNCTION_ARGS) {
   char iso2[2];
   uint64_t lo, hi;
   bool unbounded;
   pc_format fmt = fragment_range(tidy(text_to_cstring(PG_GETARG_TEXT_PP(0))), iso2, &lo, &hi, &unbounded);

   Oid rngtypid = get_fn_expr_rettype(fcinfo->flinfo);
   if (!OidIsValid(rngtypid)) elog(ERROR, "could not determine postal_prefix() result type");

   return build_prefix_range(rngtypid, pc_assemble(iso2, fmt, lo),
                             pc_assemble(iso2, unbounded ? (pc_format) PC_FMT_END : fmt, unbounded ? 0 : hi));
}

// Planner support for postal_prefix(): given a CONSTANT fragment, replace
// the call with the constant range itself at plan time. That is what lets
// PostgreSQL's own rewrite of `col <@ <constant range>` into plain btree
// conditions (`col >= lo AND col < hi`) apply, so a prefix search uses the index -- a STABLE
// function call is not a constant, so without this `pc <@ postal_prefix(..)`
// is correct but a filter over the whole index.
//
// postal_prefix() is STABLE, not IMMUTABLE, because the answer depends on
// which format a country is assigned (postal_code_country_formats). Folding
// it into a plan would let a long-lived cached plan keep a range computed
// under an assignment that has since changed. So the folded plan is made to
// depend on that table (relationOids) and a statement trigger on the table
// invalidates every plan that depends on it whenever it changes (see
// postal_code_formats_changed). Anything that can't be tied to the table, or
// isn't a plain constant, is left alone and computed at run time.
PG_FUNCTION_INFO_V1(postal_code_prefix_support);

// Non-raising fragment -> [lo, hi), for the partial-match operator and the
// planner support functions. False for anything that is not a valid
// fragment of an assigned country ("CC-" prefix missing, unassigned country,
// not a prefix of that format) -- the UK type's % has always meant "no
// match" rather than an error for a bad fragment, since it is meant to be
// fed arbitrary input such as a search box.
static bool fragment_range_try (const char *str, char iso2[2], pc_format *fmt,
                                postal_code *lo_pc, postal_code *hi_pc) {
   char *hyphen = strchr(str, '-');
   if (!hyphen || hyphen - str != 2) return false;

   lc_result why;
   char *format_name;
   *fmt = lookup_country_try(str, 2, iso2, &why, &format_name);
   if (why != LC_OK) return false;
   fmt_impl f;
   fmt_resolve_or_raise(*fmt, &f);
   if (!fmt_has_range(&f)) return false;

   uint64_t lo, hi = 0;
   bool unbounded;
   if (! fmt_range(&f, iso2, hyphen + 1, &lo, &hi, &unbounded)) return false;

   *lo_pc = pc_assemble(iso2, *fmt, lo);
   *hi_pc = pc_assemble(iso2, unbounded ? (pc_format) PC_FMT_END : *fmt, unbounded ? 0 : hi);
   return true;
}

// to_postal_prefix(fragment): postal_prefix() that returns NULL for text that is not a fragment
// (no CC-, an unassigned country, not a prefix of that format) instead of raising -- the way
// to_postal_code() relates to ::postal_code, for checking or loading arbitrary input.
PG_FUNCTION_INFO_V1(postal_code_prefix_lenient);

Datum postal_code_prefix_lenient (PG_FUNCTION_ARGS) {
   char iso2[2];
   pc_format fmt;
   postal_code lo_pc, hi_pc;
   if (! fragment_range_try(tidy(text_to_cstring(PG_GETARG_TEXT_PP(0))), iso2, &fmt, &lo_pc, &hi_pc))
      PG_RETURN_NULL();

   Oid rngtypid = get_fn_expr_rettype(fcinfo->flinfo);
   if (!OidIsValid(rngtypid)) elog(ERROR, "could not determine to_postal_prefix() result type");
   return build_prefix_range(rngtypid, lo_pc, hi_pc);
}

// Plan-time version for the support functions: only for a CONSTANT, non-NULL
// fragment, and only when the folded plan can be tied to the country->format
// table so it is invalidated when that changes (see below). On success
// registers that dependency. False means "don't fold": leave the call for
// run time, where a bad fragment behaves exactly as it always does.
static bool plan_fragment (SupportRequestSimplify *req, Node *fragexpr, Oid funcid,
                           postal_code *lo_pc, postal_code *hi_pc) {
   if (req->root == NULL) return false;
   if (!IsA(fragexpr, Const) || ((Const *) fragexpr)->constisnull) return false;

   Oid relid = get_relname_relid("postal_code_user_countries", get_func_namespace(funcid));
   if (!OidIsValid(relid)) return false;

   char iso2[2];
   pc_format fmt;
   if (! fragment_range_try(TextDatumGetCString(((Const *) fragexpr)->constvalue), iso2, &fmt, lo_pc, hi_pc))
      return false;

   req->root->glob->relationOids = lappend_oid(req->root->glob->relationOids, relid);
   return true;
}

Datum postal_code_prefix_support (PG_FUNCTION_ARGS) {
   Node *rawreq = (Node *) PG_GETARG_POINTER(0);

   if (!IsA(rawreq, SupportRequestSimplify)) PG_RETURN_POINTER(NULL);

   SupportRequestSimplify *req = (SupportRequestSimplify *) rawreq;
   FuncExpr *fexpr = req->fcall;
   if (list_length(fexpr->args) != 1) PG_RETURN_POINTER(NULL);

   postal_code lo, hi;
   if (! plan_fragment(req, (Node *) linitial(fexpr->args), fexpr->funcid, &lo, &hi))
      PG_RETURN_POINTER(NULL);

   PG_RETURN_POINTER(makeConst(fexpr->funcresulttype, -1, InvalidOid, -1,
                               build_prefix_range(fexpr->funcresulttype, lo, hi), false, false));
}

// pc % 'GB-LS24': does pc start with the fragment? The UK type's operator,
// ported -- same meaning, same leniency (a fragment that isn't one matches
// nothing, and its negator !% matches everything), and `pc % 'CC-xxx'` is the
// same test as `pc <@ postal_prefix('CC-xxx')` except that a bad fragment is
// false rather than an error.
PG_FUNCTION_INFO_V1(postal_code_partial);

Datum postal_code_partial (PG_FUNCTION_ARGS) {
   postal_code pc = PG_GETARG_POSTAL_CODE(0);
   char iso2[2];
   pc_format fmt;
   postal_code lo, hi;

   if (! fragment_range_try(tidy(text_to_cstring(PG_GETARG_TEXT_PP(1))), iso2, &fmt, &lo, &hi))
      PG_RETURN_BOOL(false);
   PG_RETURN_BOOL(pc >= lo && pc < hi);
}

PG_FUNCTION_INFO_V1(postal_code_not_partial);

Datum postal_code_not_partial (PG_FUNCTION_ARGS) {
   postal_code pc = PG_GETARG_POSTAL_CODE(0);
   char iso2[2];
   pc_format fmt;
   postal_code lo, hi;

   if (! fragment_range_try(tidy(text_to_cstring(PG_GETARG_TEXT_PP(1))), iso2, &fmt, &lo, &hi))
      PG_RETURN_BOOL(true);
   PG_RETURN_BOOL(!(pc >= lo && pc < hi));
}

// Planner support for %: `col % 'constant fragment'` becomes
// `col >= lo AND col < hi` at plan time, so it uses a btree index through the
// ordinary, sound >= and < strategies (the UK type does the same; % itself is
// not an equivalence relation and is deliberately NOT registered in the btree
// opfamily). The fold depends on the country->format table exactly as
// postal_prefix() does (same dependency, same invalidating trigger). Declines
// -- leaving the plain function, which is always correct -- for a non-constant
// fragment, a NULL, or a fragment that isn't valid, so the runtime result
// (false) is never changed by the optimizer.
PG_FUNCTION_INFO_V1(postal_code_partial_support);

Datum postal_code_partial_support (PG_FUNCTION_ARGS) {
   Node *rawreq = (Node *) PG_GETARG_POINTER(0);

   if (!IsA(rawreq, SupportRequestSimplify)) PG_RETURN_POINTER(NULL);

   SupportRequestSimplify *req = (SupportRequestSimplify *) rawreq;
   FuncExpr *fcall = req->fcall;
   if (list_length(fcall->args) != 2) PG_RETURN_POINTER(NULL);

   Node *colexpr  = (Node *) linitial(fcall->args);
   Node *fragexpr = (Node *) lsecond(fcall->args);

   postal_code lo, hi;
   if (! plan_fragment(req, fragexpr, fcall->funcid, &lo, &hi)) PG_RETURN_POINTER(NULL);

   Oid typ = exprType(colexpr);
   Oid geOid = OpernameGetOprid(list_make1(makeString(">=")), typ, typ);
   Oid ltOid = OpernameGetOprid(list_make1(makeString("<")),  typ, typ);
   if (!OidIsValid(geOid) || !OidIsValid(ltOid)) PG_RETURN_POINTER(NULL);

   Const *loConst = makeConst(typ, -1, InvalidOid, sizeof(int64), Int64GetDatum((int64) lo), false, FLOAT8PASSBYVAL);
   Const *hiConst = makeConst(typ, -1, InvalidOid, sizeof(int64), Int64GetDatum((int64) hi), false, FLOAT8PASSBYVAL);

   OpExpr *ge = (OpExpr *) make_opclause(geOid, BOOLOID, false, (Expr *) colexpr, (Expr *) loConst, InvalidOid, InvalidOid);
   set_opfuncid(ge);
   OpExpr *lt = (OpExpr *) make_opclause(ltOid, BOOLOID, false, (Expr *) colexpr, (Expr *) hiConst, InvalidOid, InvalidOid);
   set_opfuncid(lt);

   PG_RETURN_POINTER(make_andclause(list_make2(ge, lt)));
}

// Statement-level trigger on postal_code_user_countries (and the templates table): DML does not
// normally invalidate cached plans that depend on a table (only schema
// changes do), so say so explicitly. This is what makes the plan-time
// folding in postal_code_prefix_support() safe.
PG_FUNCTION_INFO_V1(postal_code_formats_changed);

Datum postal_code_formats_changed (PG_FUNCTION_ARGS) {
   if (!CALLED_AS_TRIGGER(fcinfo))
      elog(ERROR, "postal_code_formats_changed() must be called as a trigger");

   CacheInvalidateRelcacheByRelid(RelationGetRelid(((TriggerData *) fcinfo->context)->tg_relation));
   return PointerGetDatum(NULL);
}


// Validates a template (postal_code_template.h) and returns it in canonical
// form, or raises saying what is wrong with it. add_country_template() runs
// every template through this before it gets a slot.
PG_FUNCTION_INFO_V1(postal_code_template_check);

Datum postal_code_template_check (PG_FUNCTION_ARGS) {
   char *spec = text_to_cstring(PG_GETARG_TEXT_PP(0));
   pc_template t;
   char err[160];

   if (!pc_template_compile(spec, &t, err, sizeof err))
      ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                      errmsg (_("invalid postal code template \"%s\": %s"), spec, err),
                      errhint(_("N is a digit, A a letter, X either; ' ' and '-' are separators; one optional [ ] group may end it, e.g. \"NNNNN[-NNNN]\""))));

   PG_RETURN_TEXT_P(cstring_to_text(t.spec));
}


// outcode(pc) / district(pc): the area part of a postcode, as a complete
// valid postcode of its own ('GB-SW1A 1AA' -> 'GB-SW1A'). NULL where the
// format has no distinct outcode (FR, CZ, LU) and for the end-of-country
// bound, which is not a postcode. Depends only on the value's own bits --
// the format is in them, so the country->format table is never consulted --
// which is why it can be IMMUTABLE and used in an index.
PG_FUNCTION_INFO_V1(postal_code_outcode);

Datum postal_code_outcode (PG_FUNCTION_ARGS) {
   postal_code pc = PG_GETARG_POSTAL_CODE(0);
   pc_format fmt = (pc_format) GET_FORMAT(pc);

   fmt_impl f;
   if (!fmt_resolve(fmt, &f) || !fmt_has_outcode(&f))
      PG_RETURN_NULL();

   SET_PAYLOAD(pc, fmt_outcode(&f, GET_PAYLOAD(pc)));
   PG_RETURN_POSTAL_CODE(pc);
}


// ---- country lock: postal_code('US') -----------------------------------------
// PostGIS locks a geometry column to an SRID with a type modifier, and so
// does this: CREATE TABLE t (pc postal_code('US')). Quote the code -- an
// unquoted one that happens to be an SQL keyword (IN, TO, ...) won't parse.
//
// typmod_in deliberately validates only the SHAPE (two letters), not whether
// the country is currently assigned a format: a column definition must be
// restorable from a dump before the country assignments' data is, and a
// lock to a country nothing is assigned to is harmless -- every insert into
// it fails loudly instead.
PG_FUNCTION_INFO_V1(postal_code_typmod_in);

Datum postal_code_typmod_in (PG_FUNCTION_ARGS) {
   ArrayType *ta = PG_GETARG_ARRAYTYPE_P(0);
   Datum *elems;
   int n;
   deconstruct_array(ta, CSTRINGOID, -2, false, TYPALIGN_CHAR, &elems, NULL, &n);

   if (n != 1)
      ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                      errmsg (_("postal_code takes one type modifier, a two-letter country code")),
                      errhint(_("for example postal_code('US')"))));

   char *cc = DatumGetCString(elems[0]);
   if (strlen(cc) != 2 || !ascii_alpha(cc[0]) || !ascii_alpha(cc[1]))
      ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                      errmsg (_("invalid type modifier \"%s\" for postal_code: expected a two-letter country code"), cc),
                      errhint(_("for example postal_code('US')"))));

   PG_RETURN_INT32((int32) pc_pack_country(ascii_upper(cc[0]), ascii_upper(cc[1])));
}

PG_FUNCTION_INFO_V1(postal_code_typmod_out);

Datum postal_code_typmod_out (PG_FUNCTION_ARGS) {
   int32 typmod = PG_GETARG_INT32(0);
   char *res = palloc(5);
   if (typmod >= 0 && (typmod >> PC_LETTER_BITS) < 26 && (typmod & ((1 << PC_LETTER_BITS) - 1)) < 26) {
      char iso2[2];
      pc_unpack_country((uint16_t) typmod, iso2);
      sprintf(res, "(%c%c)", iso2[0], iso2[1]);
   } else {
      strcpy(res, "(?)");
   }
   PG_RETURN_CSTRING(res);
}

// The length-coercion cast PostgreSQL applies when a value goes into a
// column with a type modifier (INSERT, UPDATE, ::postal_code('US'), ALTER
// COLUMN ... TYPE): the value's country must be the column's. Only on
// assignment and casts, as with every typmod (varchar(n), geometry(Point,
// 4326)) -- a value merely returned from a function is not re-checked.
PG_FUNCTION_INFO_V1(postal_code_enforce);

Datum postal_code_enforce (PG_FUNCTION_ARGS) {
   postal_code pc = PG_GETARG_POSTAL_CODE(0);
   check_lock(pc, PG_GETARG_INT32(1));
   PG_RETURN_POSTAL_CODE(pc);
}


PG_FUNCTION_INFO_V1(postal_code_country);

Datum postal_code_country (PG_FUNCTION_ARGS) {
   postal_code pc = PG_GETARG_POSTAL_CODE(0);
   char iso2[2];
   pc_unpack_country((uint16_t) GET_COUNTRY(pc), iso2);

   char buf[3] = { iso2[0], iso2[1], '\0' };
   PG_RETURN_TEXT_P(cstring_to_text(buf));
}
