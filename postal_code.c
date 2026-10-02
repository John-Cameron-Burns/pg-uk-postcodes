#include <string.h>
#include <stdio.h>

#include <postgres.h>
#include <varatt.h>
#include <fmgr.h>
#include <utils/builtins.h>
#include <libpq/pqformat.h>
#include <access/htup_details.h>
#include <catalog/namespace.h>
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
Datum postal_code_lower_bound (PG_FUNCTION_ARGS);
Datum postal_code_upper_bound (PG_FUNCTION_ARGS);
Datum postal_code_prefix (PG_FUNCTION_ARGS);
Datum postal_code_prefix_support (PG_FUNCTION_ARGS);
Datum postal_code_formats_changed (PG_FUNCTION_ARGS);
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

   // "CC-~" is the end-of-country bound (see PC_FMT_END): not a postcode,
   // only ever the upper end of a range. It must be written exactly, so an
   // empty or missing national code ("US-") is still an error rather than
   // quietly becoming a marker.
   if (strcmp(hyphen + 1, "~") == 0) {
      char c0 = str[0], c1 = str[1];
      if (c0 >= 'a' && c0 <= 'z') c0 = (char) (c0 - 32);
      if (c1 >= 'a' && c1 <= 'z') c1 = (char) (c1 - 32);
      if (c0 < 'A' || c0 > 'Z' || c1 < 'A' || c1 > 'Z')
         ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                         errmsg (_("\"%.2s\" is not a two-letter country code"), str)));
      PG_RETURN_POSTAL_CODE(pc_assemble((char[2]){ c0, c1 }, (pc_format) PC_FMT_END, 0));
   }

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

   if (fmt == PC_FMT_END && GET_PAYLOAD(pc) == 0) {      // the end-of-country bound
      char iso2e[2];
      pc_unpack_country((uint16_t) GET_COUNTRY(pc), iso2e);
      char *end = palloc(5);
      sprintf(end, "%c%c-~", iso2e[0], iso2e[1]);
      PG_RETURN_CSTRING(end);
   }

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
   uint16_t country = (uint16_t) GET_COUNTRY(pc);
   bool end_bound = fmt == PC_FMT_END && GET_PAYLOAD(pc) == 0 &&
                    (country >> PC_LETTER_BITS) < 26 && (country & ((1 << PC_LETTER_BITS) - 1)) < 26;
   if (!end_bound &&
       (fmt == PC_FMT_UNKNOWN || fmt >= PC_FMT_MAX || !pc_formats[fmt] ||
        ! pc_formats[fmt]->valid(GET_PAYLOAD(pc))))
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

   if (!pc_formats[fmt]->range)
      ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                      errmsg (_("the %s postal code format does not support ranges"), pc_formats[fmt]->name)));

   if (! pc_formats[fmt]->range(hyphen + 1, lo, hi, unbounded))
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("cannot parse \"%s\" as a fragment of a %s postal code"),
                              hyphen + 1, pc_formats[fmt]->name)));
   return fmt;
}

// The smallest VALID value that starts with the fragment (for 'CA-K', the
// outcode 'CA-K0A'); included in the range.
PG_FUNCTION_INFO_V1(postal_code_lower_bound);

Datum postal_code_lower_bound (PG_FUNCTION_ARGS) {
   char iso2[2];
   uint64_t lo, hi;
   bool unbounded;
   pc_format fmt = fragment_range(text_to_cstring(PG_GETARG_TEXT_PP(0)), iso2, &lo, &hi, &unbounded);
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
   pc_format fmt = fragment_range(text_to_cstring(PG_GETARG_TEXT_PP(0)), iso2, &lo, &hi, &unbounded);
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
   pc_format fmt = fragment_range(text_to_cstring(PG_GETARG_TEXT_PP(0)), iso2, &lo, &hi, &unbounded);

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

Datum postal_code_prefix_support (PG_FUNCTION_ARGS) {
   Node *rawreq = (Node *) PG_GETARG_POINTER(0);

   if (!IsA(rawreq, SupportRequestSimplify)) PG_RETURN_POINTER(NULL);

   SupportRequestSimplify *req = (SupportRequestSimplify *) rawreq;
   FuncExpr *fexpr = req->fcall;
   if (req->root == NULL || list_length(fexpr->args) != 1) PG_RETURN_POINTER(NULL);

   Node *arg = (Node *) linitial(fexpr->args);
   if (!IsA(arg, Const) || ((Const *) arg)->constisnull) PG_RETURN_POINTER(NULL);

   Oid relid = get_relname_relid("postal_code_country_formats", get_func_namespace(fexpr->funcid));
   if (!OidIsValid(relid)) PG_RETURN_POINTER(NULL);

   // From here every failure means "not foldable": leave it to run time,
   // where the same call raises a proper error for a bad fragment.
   char *str = TextDatumGetCString(((Const *) arg)->constvalue);
   char *hyphen = strchr(str, '-');
   if (!hyphen || hyphen - str != 2) PG_RETURN_POINTER(NULL);

   char iso2[2];
   lc_result why;
   char *format_name;
   pc_format fmt = lookup_country_try(str, 2, iso2, &why, &format_name);
   if (why != LC_OK || !pc_formats[fmt]->range) PG_RETURN_POINTER(NULL);

   uint64_t lo, hi = 0;
   bool unbounded;
   if (! pc_formats[fmt]->range(hyphen + 1, &lo, &hi, &unbounded)) PG_RETURN_POINTER(NULL);

   req->root->glob->relationOids = lappend_oid(req->root->glob->relationOids, relid);

   Datum range = build_prefix_range(fexpr->funcresulttype, pc_assemble(iso2, fmt, lo),
                                    pc_assemble(iso2, unbounded ? (pc_format) PC_FMT_END : fmt, unbounded ? 0 : hi));
   PG_RETURN_POINTER(makeConst(fexpr->funcresulttype, -1, InvalidOid, -1, range, false, false));
}

// Statement-level trigger on postal_code_country_formats: DML does not
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


PG_FUNCTION_INFO_V1(postal_code_country);

Datum postal_code_country (PG_FUNCTION_ARGS) {
   postal_code pc = PG_GETARG_POSTAL_CODE(0);
   char iso2[2];
   pc_unpack_country((uint16_t) GET_COUNTRY(pc), iso2);

   char buf[3] = { iso2[0], iso2[1], '\0' };
   PG_RETURN_TEXT_P(cstring_to_text(buf));
}
