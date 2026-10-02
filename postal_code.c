#include <string.h>
#include <stdio.h>

#include <postgres.h>
#include <varatt.h>
#include <fmgr.h>
#include <utils/builtins.h>
#include <libpq/pqformat.h>

// PG_MODULE_MAGIC lives in postcode.c -- exactly one per shared
// library, and postal_code.o/postcode.o link into the same
// postcode.so (one package, both types; see this repo's Makefile).

#include "postal_code.h"
#include "postal_code_fmt.h"
#include "postal_code_country.h"

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

   *format_name = pc_lookup_country_format(out_iso2);
   if (!*format_name) { *why = LC_NO_ASSIGNMENT; return PC_FMT_UNKNOWN; }

   pc_format fmt = pc_format_by_name(*format_name);
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


PG_FUNCTION_INFO_V1(postal_code_in);

Datum postal_code_in (PG_FUNCTION_ARGS) {
   char *str = PG_GETARG_CSTRING(0);

   // UPU form: ISO 3166-1 alpha-2, a hyphen, then the national code
   // ("US-90210-1234"). The country is always exactly two characters,
   // so the FIRST hyphen is unambiguously the delimiter even for
   // national codes that contain hyphens of their own (US ZIP+4, BR CEP).
   char *hyphen = strchr(str, '-');
   if (!hyphen || hyphen - str != 2)
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("postal_code requires a two-letter country prefix, e.g. \"US-90210\"")),
                      errhint(_("got \"%s\""), str)));

   char iso2[2];
   pc_format fmt = lookup_country(str, 2, iso2);

   uint64_t payload;
   if (! pc_formats[fmt]->parse(hyphen + 1, false, &payload) ||
       ! pc_formats[fmt]->valid(payload))
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("cannot parse \"%s\" as a %s postal code"),
                              hyphen + 1, pc_formats[fmt]->name)));

   PG_RETURN_POSTAL_CODE(pc_assemble(iso2, fmt, payload));
}


PG_FUNCTION_INFO_V1(postal_code_out);

Datum postal_code_out (PG_FUNCTION_ARGS) {
   postal_code pc = PG_GETARG_POSTAL_CODE(0);

   pc_format fmt = (pc_format) GET_FORMAT(pc);
   if (fmt == PC_FMT_UNKNOWN || fmt >= PC_FMT_MAX || !pc_formats[fmt])
      ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
                      errmsg (_("cannot render corrupted binary data to text"))));

   char iso2[2];
   pc_unpack_country((uint16_t) GET_COUNTRY(pc), iso2);

   char *out = palloc(3 + pc_formats[fmt]->max_text_len + 1); // "CC-" + code + NUL
   int n = sprintf(out, "%c%c-", iso2[0], iso2[1]);
   pc_formats[fmt]->render(GET_PAYLOAD(pc), out + n);

   PG_RETURN_CSTRING(out);
}


PG_FUNCTION_INFO_V1(postal_code_recv);

Datum postal_code_recv (PG_FUNCTION_ARGS) {
   postal_code pc = (postal_code) pq_getmsgint64((StringInfo) PG_GETARG_POINTER(0));

   pc_format fmt = (pc_format) GET_FORMAT(pc);
   if (fmt == PC_FMT_UNKNOWN || fmt >= PC_FMT_MAX || !pc_formats[fmt] ||
       ! pc_formats[fmt]->valid(GET_PAYLOAD(pc)))
      ereport(ERROR, (errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
                      errmsg (_("received binary data is invalid for type postal_code")),
                      errhint(_("server binary format version is %s"), STR(EXTVERSION))));

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


// Two-argument constructor, analogous to PostGIS's
// ST_GeomFromText(wkt, srid): for callers that already have country
// and national code as separate values and don't want to build
// (and this function then reparse) a "CC-code" string themselves.
// Unlike ST_SetSRID(), there is no cheap "retag an existing value"
// counterpart -- see the country/format design notes above
// pc_format for why that would silently corrupt the payload for
// any two formats that aren't bit-compatible.
PG_FUNCTION_INFO_V1(postal_code_from_parts);

Datum postal_code_from_parts (PG_FUNCTION_ARGS) {
   text *cc_text   = PG_GETARG_TEXT_PP(0);
   text *code_text = PG_GETARG_TEXT_PP(1);

   char *cc   = text_to_cstring(cc_text);
   char *code = text_to_cstring(code_text);

   char iso2[2];
   pc_format fmt = lookup_country(cc, strlen(cc), iso2);

   uint64_t payload;
   if (! pc_formats[fmt]->parse(code, false, &payload) ||
       ! pc_formats[fmt]->valid(payload))
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("cannot parse \"%s\" as a %s postal code"), code, pc_formats[fmt]->name)));

   PG_RETURN_POSTAL_CODE(pc_assemble(iso2, fmt, payload));
}


// NULL-returning counterparts of the strict constructors, for loading feeds
// that contain rows which are not valid postcodes (the same role
// topostcode() plays for the UK type): a malformed or unassigned country
// code, or a national code that doesn't parse, yields NULL instead of an
// error that aborts the whole COPY/INSERT. Strictness stays the default;
// this is opt-in by name. A country assigned to a format this build
// doesn't have is a configuration fault, not bad input, and still raises.
// Two forms, mirroring ::postal_code and postal_code(cc, code):
//   to_postal_code('FR-75054 CEDEX 01')   and   to_postal_code('FR', '75054 CEDEX 01')
static bool lenient_build (const char *cc, size_t len, const char *code, postal_code *out) {
   char iso2[2];
   lc_result why;
   char *format_name;
   pc_format fmt = lookup_country_try(cc, len, iso2, &why, &format_name);
   if (why == LC_BAD_SHAPE || why == LC_NO_ASSIGNMENT) return false;
   if (why != LC_OK) lookup_country_raise(why, cc, len, iso2, format_name);

   uint64_t payload;
   if (! pc_formats[fmt]->parse(code, false, &payload) ||
       ! pc_formats[fmt]->valid(payload))
      return false;

   *out = pc_assemble(iso2, fmt, payload);
   return true;
}

PG_FUNCTION_INFO_V1(postal_code_lenient);

Datum postal_code_lenient (PG_FUNCTION_ARGS) {
   char *cc   = text_to_cstring(PG_GETARG_TEXT_PP(0));
   char *code = text_to_cstring(PG_GETARG_TEXT_PP(1));

   postal_code pc;
   if (! lenient_build(cc, strlen(cc), code, &pc)) PG_RETURN_NULL();
   PG_RETURN_POSTAL_CODE(pc);
}


PG_FUNCTION_INFO_V1(postal_code_lenient_text);

Datum postal_code_lenient_text (PG_FUNCTION_ARGS) {
   char *str = text_to_cstring(PG_GETARG_TEXT_PP(0));

   // same shape rule as postal_code_in(): exactly two characters, a hyphen
   char *hyphen = strchr(str, '-');
   if (!hyphen || hyphen - str != 2) PG_RETURN_NULL();

   postal_code pc;
   if (! lenient_build(str, 2, hyphen + 1, &pc)) PG_RETURN_NULL();
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
