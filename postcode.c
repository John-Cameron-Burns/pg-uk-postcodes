#include <postgres.h>
#if PG_VERSION_NUM >= 160000
#include <varatt.h>      // split out of postgres.h in PostgreSQL 16
#endif
#include <utils/builtins.h>
#include <libpq/pqformat.h>

// For postcode_eq_partial_support() -- planner-support-function API used
// to rewrite % into an indexable range at plan time (see its own comment
// below for why, and why this is different from -- and sound where --
// 1.3.0's removed btree strategy-3 registration wasn't).
#include <nodes/nodeFuncs.h>    // exprType(), set_opfuncid()
#include <nodes/makefuncs.h>    // makeConst(), make_opclause(), make_andclause()
#include <nodes/value.h>        // makeString()
#include <nodes/supportnodes.h> // SupportRequestSimplify
#include <catalog/namespace.h>  // OpernameGetOprid()

#ifdef PG_MODULE_MAGIC
PG_MODULE_MAGIC;
#endif

#include "postcode.h"
#include "binfmt.h"

#define PG_RETURN_POSTCODE(p) return UInt32GetDatum(p)
#define PG_GETARG_POSTCODE(n) DatumGetUInt32(PG_GETARG_DATUM(n))

#define PG_RETURN_DPS(p)      return UInt8GetDatum(p)
#define PG_GETARG_DPS(n)      DatumGetUInt8(PG_GETARG_DATUM(n))

Datum postcode_in             (PG_FUNCTION_ARGS);
Datum postcode_out            (PG_FUNCTION_ARGS);
Datum postcode_recv           (PG_FUNCTION_ARGS);
Datum postcode_send           (PG_FUNCTION_ARGS);
Datum postcode_validate       (PG_FUNCTION_ARGS);
Datum postcode_cmp            (PG_FUNCTION_ARGS);
Datum postcode_eq             (PG_FUNCTION_ARGS);
Datum postcode_ne             (PG_FUNCTION_ARGS);
Datum postcode_lt             (PG_FUNCTION_ARGS);
Datum postcode_gt             (PG_FUNCTION_ARGS);
Datum postcode_lte            (PG_FUNCTION_ARGS);
Datum postcode_gte            (PG_FUNCTION_ARGS);
Datum postcode_cmp_partial    (PG_FUNCTION_ARGS);
Datum postcode_eq_partial     (PG_FUNCTION_ARGS);
Datum postcode_ne_partial     (PG_FUNCTION_ARGS);
Datum postcode_range_lower    (PG_FUNCTION_ARGS);
Datum postcode_range_upper    (PG_FUNCTION_ARGS);
Datum postcode_eq_partial_support (PG_FUNCTION_ARGS);
Datum postcode_to_text        (PG_FUNCTION_ARGS);
Datum text_to_postcode        (PG_FUNCTION_ARGS);

Datum dps_in                  (PG_FUNCTION_ARGS);
Datum dps_out                 (PG_FUNCTION_ARGS);
Datum dps_recv                (PG_FUNCTION_ARGS);
Datum dps_send                (PG_FUNCTION_ARGS);
Datum dps_validate            (PG_FUNCTION_ARGS);
Datum dps_cmp                 (PG_FUNCTION_ARGS);
Datum dps_eq                  (PG_FUNCTION_ARGS);
Datum dps_ne                  (PG_FUNCTION_ARGS);
Datum dps_lt                  (PG_FUNCTION_ARGS);
Datum dps_gt                  (PG_FUNCTION_ARGS);
Datum dps_lte                 (PG_FUNCTION_ARGS);
Datum dps_gte                 (PG_FUNCTION_ARGS);
Datum dps_to_text             (PG_FUNCTION_ARGS);
Datum text_to_dps             (PG_FUNCTION_ARGS);

__attribute__((warn_unused_result))
static inline postcode postcode_mask (postcode a, postcode b) {
   if (! GET_AREA(b))      return 0;
   if (! GET_DISTRICT1(b)) return MASK_DISTRICT(a);
   if (! GET_SECTOR(b))    return MASK_SECTOR(a);
   if (! GET_WALK1(b))     return MASK_WALK(a);
   return a;
}

// Number of low-order bits NOT pinned by a parsed partial fragment b --
// mirrors postcode_mask()'s own branch structure exactly (same ordering,
// same fields), just returning a bit count instead of directly clearing
// them. Used by range_lower()/range_upper() below. Returns -1 for an
// empty/invalid fragment (no area given at all).
__attribute__((warn_unused_result))
static inline int postcode_free_bits (postcode b) {
   if (! GET_AREA(b))      return -1;
   if (! GET_DISTRICT1(b)) return 24;
   if (! GET_SECTOR(b))    return 14;
   if (! GET_WALK1(b))     return 10;
   return 0;
}

// Raises sector/walk1/walk2 from "unset" (0) to their real minimum (1)
// wherever they're currently unset -- turns a range_lower()/
// range_upper() boundary from a raw partial bit pattern into a real,
// valid, renderable postcode, without changing what it compares as (see
// the long comment above postcode_range_lower()/postcode_range_upper()
// for why that holds). Must only ever be applied to an already-computed
// boundary value, never folded into the free-bits arithmetic itself --
// postcode_free_bits() has to see which field is genuinely absent in the
// fragment's own raw parse to land the boundary in the right place;
// filling first would hide that from it.
//
// district1 is included (not just sector/walk): unlike district2, a
// real postcode can never have district1 absent -- postcode_binchk()
// requires it -- so "BA" (area only) fills to "BA0 0AA", not something
// still missing its district entirely. district2 itself is deliberately
// never touched -- see the comment above postcode_range_lower() for why.
__attribute__((warn_unused_result))
static inline postcode postcode_fill_boundary (postcode p) {
   if (! GET_DISTRICT1(p)) SET_DISTRICT1(p, 1);
   if (! GET_SECTOR(p))    SET_SECTOR(p, 1);
   if (! GET_WALK1(p))     SET_WALK1(p, 1);
   if (! GET_WALK2(p))     SET_WALK2(p, 1);
   return p;
}


PG_FUNCTION_INFO_V1(postcode_in);

Datum postcode_in (PG_FUNCTION_ARGS) {
   postcode p = postcode_parse(PG_GETARG_CSTRING(0), false);

   if (p == 0)
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("cannot parse input for type postcode"))));

   PG_RETURN_POSTCODE(p);
}


PG_FUNCTION_INFO_V1(postcode_out);

Datum postcode_out (PG_FUNCTION_ARGS) {
   postcode p = PG_GETARG_POSTCODE(0);

   if (! postcode_binchk(p))
      ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
                      errmsg (_("cannot render corrupted binary data to text"))));

   // postcode_render() writes up to 8 visible characters (2-letter area +
   // 2-char district + space + sector + 2-char walk, e.g. "SW1A 1AA") plus
   // a null terminator -- 9 bytes, not 8. This under-allocation has been a
   // one-byte heap overflow for every postcode with a 2-letter area and a
   // 2-char district since this function was written.
   char *str = palloc(9);

   // postcode_render() is also used by postcode_to_char() and the named
   // postcode_to_text() helper, where partial values are representable.
   // The type output function has already rejected those values above.
   postcode_render(p, str);

   PG_RETURN_CSTRING(str);
}


PG_FUNCTION_INFO_V1(postcode_recv);

Datum postcode_recv (PG_FUNCTION_ARGS) {
   postcode p = pq_getmsgint((StringInfo) PG_GETARG_POINTER(0), sizeof(postcode));

   if (! postcode_binchk(p))
      ereport(ERROR, (errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
                      errmsg (_("received binary data is invalid for type postcode")),
                      errhint(_("server binary format version is %s"), STR(EXTVERSION))));

   PG_RETURN_POSTCODE(p);
}


PG_FUNCTION_INFO_V1(postcode_send);

Datum postcode_send (PG_FUNCTION_ARGS) {
   StringInfoData b;
   pq_begintypsend(&b);
   pq_sendint(&b, PG_GETARG_POSTCODE(0), sizeof(postcode));
   PG_RETURN_BYTEA_P(pq_endtypsend(&b));
}


PG_FUNCTION_INFO_V1(postcode_validate);

Datum postcode_validate (PG_FUNCTION_ARGS) {
   postcode p = postcode_parse(text_to_cstring(PG_GETARG_TEXT_P(0)), false);
   PG_RETURN_BOOL(p ? TRUE : FALSE);
}


PG_FUNCTION_INFO_V1(postcode_cmp);

Datum postcode_cmp (PG_FUNCTION_ARGS) {
   postcode a = PG_GETARG_POSTCODE(0),
            b = PG_GETARG_POSTCODE(1);

   if (a == b) PG_RETURN_INT32( 0);
   if (a >  b) PG_RETURN_INT32( 1);
   else        PG_RETURN_INT32(-1);
}


PG_FUNCTION_INFO_V1(postcode_eq);

Datum postcode_eq (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_POSTCODE(0) == PG_GETARG_POSTCODE(1));
}


PG_FUNCTION_INFO_V1(postcode_ne);

Datum postcode_ne (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_POSTCODE(0) != PG_GETARG_POSTCODE(1));
}


PG_FUNCTION_INFO_V1(postcode_lt);

Datum postcode_lt (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_POSTCODE(0) < PG_GETARG_POSTCODE(1));
}


PG_FUNCTION_INFO_V1(postcode_gt);

Datum postcode_gt (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_POSTCODE(0) > PG_GETARG_POSTCODE(1));
}


PG_FUNCTION_INFO_V1(postcode_lte);

Datum postcode_lte (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_POSTCODE(0) <= PG_GETARG_POSTCODE(1));
}


PG_FUNCTION_INFO_V1(postcode_gte);

Datum postcode_gte (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_POSTCODE(0) >= PG_GETARG_POSTCODE(1));
}


PG_FUNCTION_INFO_V1(postcode_cmp_partial);

Datum postcode_cmp_partial (PG_FUNCTION_ARGS) {
   postcode b = postcode_parse(text_to_cstring(PG_GETARG_TEXT_P(1)), true);
   postcode a = postcode_mask(PG_GETARG_POSTCODE(0), b);

   if (b == 0) PG_RETURN_INT32(-1); // invalid postcode fragment
   if (a == b) PG_RETURN_INT32( 0);
   if (a >  b) PG_RETURN_INT32( 1);
   else        PG_RETURN_INT32(-1);
}


PG_FUNCTION_INFO_V1(postcode_eq_partial);

Datum postcode_eq_partial (PG_FUNCTION_ARGS) {
   postcode b = postcode_parse(text_to_cstring(PG_GETARG_TEXT_P(1)), true);
   postcode a = postcode_mask(PG_GETARG_POSTCODE(0), b);

   if (b == 0) PG_RETURN_BOOL(false); // invalid postcode fragment
   PG_RETURN_BOOL(a == b);
}


// Planner support function for %, attached via SUPPORT in the catalog
// (see the CREATE OR REPLACE in the upgrade script). Rewrites
// `col % 'fragment'` -- where 'fragment' is a plan-time constant -- into
// `col >= range_lower('fragment') AND col < range_upper('fragment')`
// during the planner's constant-folding pass, so % gets an index-assisted
// plan through the ordinary, already-sound </>= strategies, with no
// opfamily trickery and none of 1.3.0's soundness bug (see the comment
// above CREATE OPERATOR FAMILY postcode_ops in the SQL script): the
// rewrite happens once, at plan time, against a literal fragment, not by
// telling the index AM that % itself is an equivalence relation, which
// it isn't.
//
// Declines (returns NULL, per the SupportRequestSimplify contract --
// "must return NULL, not fail, if it cannot handle the given case") for
// anything it isn't confident about, leaving the plain function call
// (always correct, just unindexed) to run as before: a non-constant
// fragment (a column or parameter, not known until execution), a NULL
// constant, or a fragment postcode_free_bits() rejects. The last case
// deliberately doesn't raise here even though range_lower()/
// range_upper() themselves do for the same input (see their own
// comment) -- postcode_eq_partial() has always returned false rather
// than erroring for an invalid fragment, and a plan-time optimization
// has no business changing that runtime-visible behaviour; declining
// just means the existing, already-correct function runs and returns
// false as it always has.
//
// Mirrors postcode_range_lower()/postcode_range_upper()'s own bounds
// logic exactly (same postcode_parse()/postcode_free_bits() calls) so
// this can't drift out of sync with what those functions -- or %
// itself, via postcode_mask() -- consider a match, the same discipline
// postcode_free_bits()'s own comment already holds itself to.
PG_FUNCTION_INFO_V1(postcode_eq_partial_support);

Datum postcode_eq_partial_support (PG_FUNCTION_ARGS) {
   Node *rawreq = (Node *) PG_GETARG_POINTER(0);

   if (IsA(rawreq, SupportRequestSimplify)) {
      SupportRequestSimplify *req = (SupportRequestSimplify *) rawreq;
      FuncExpr *fcall = req->fcall;
      Node *colexpr, *fragexpr;
      Const *fragconst;
      postcode lower;
      int free_bits;

      if (list_length(fcall->args) != 2)
         PG_RETURN_POINTER(NULL);

      colexpr  = (Node *) linitial(fcall->args);
      fragexpr = (Node *) lsecond(fcall->args);

      // Only a plan-time constant fragment can be turned into bounds
      // now -- a variable/parameter fragment isn't known until
      // execution, exactly like LIKE's own prefix optimization only
      // applies for a constant pattern.
      if (! IsA(fragexpr, Const))
         PG_RETURN_POINTER(NULL);

      fragconst = (Const *) fragexpr;
      if (fragconst->constisnull)
         PG_RETURN_POINTER(NULL);

      lower = postcode_parse(text_to_cstring(DatumGetTextPP(fragconst->constvalue)), true);
      free_bits = postcode_free_bits(lower);

      if (free_bits < 0)
         PG_RETURN_POINTER(NULL); // invalid fragment -- let the plain function reject it at runtime, as it always has

      {
         // Filled the same way, and for the same reason, as
         // postcode_range_lower()/postcode_range_upper()'s own results
         // (see their comment) -- doesn't change what either bound
         // compares as, only keeps this in lockstep with what those
         // functions would themselves produce for the same fragment, so
         // there's no drift between the rewritten plan's embedded
         // constants and the equivalent hand-written range_lower()/
         // range_upper() query a user would otherwise write.
         postcode lowerFilled = postcode_fill_boundary(lower);
         postcode upperFilled = postcode_fill_boundary(lower + (1u << free_bits));
         Oid postcodeOid = exprType(colexpr);
         Oid geOid = OpernameGetOprid(list_make1(makeString(">=")), postcodeOid, postcodeOid);
         Oid ltOid = OpernameGetOprid(list_make1(makeString("<")),  postcodeOid, postcodeOid);
         Const *lowerConst = makeConst(postcodeOid, -1, InvalidOid, sizeof(postcode), UInt32GetDatum(lowerFilled), false, true);
         Const *upperConst = makeConst(postcodeOid, -1, InvalidOid, sizeof(postcode), UInt32GetDatum(upperFilled), false, true);
         OpExpr *geExpr, *ltExpr;

         if (! OidIsValid(geOid) || ! OidIsValid(ltOid))
            PG_RETURN_POINTER(NULL); // shouldn't happen -- both are always defined -- but never fail a support function

         geExpr = (OpExpr *) make_opclause(geOid, BOOLOID, false, (Expr *) colexpr, (Expr *) lowerConst, InvalidOid, InvalidOid);
         set_opfuncid(geExpr);
         ltExpr = (OpExpr *) make_opclause(ltOid, BOOLOID, false, (Expr *) colexpr, (Expr *) upperConst, InvalidOid, InvalidOid);
         set_opfuncid(ltExpr);

         PG_RETURN_POINTER(make_andclause(list_make2(geExpr, ltExpr)));
      }
   }

   PG_RETURN_POINTER(NULL);
}


PG_FUNCTION_INFO_V1(postcode_ne_partial);

Datum postcode_ne_partial (PG_FUNCTION_ARGS) {
   postcode b = postcode_parse(text_to_cstring(PG_GETARG_TEXT_P(1)), true);
   postcode a = postcode_mask(PG_GETARG_POSTCODE(0), b);

   if (b == 0) PG_RETURN_BOOL(true); // invalid postcode fragment
   PG_RETURN_BOOL(a != b);
}


// range_lower()/range_upper() -- the sound, index-friendly replacement
// for indexed prefix matching. % was formerly registered under btree
// strategy 3 (the "equality" slot) to get an index-assisted plan, but
// PostgreSQL requires that strategy's operator to be a genuine
// equivalence relation for the planner's equivalence-class reasoning to
// stay sound, and % isn't one (two different postcodes can both match
// the same fragment without being equal to each other). Fixed by
// dropping that opfamily registration; these two functions express a
// fragment as a genuine half-open range instead, usable with the
// ordinary (and ordinarily correct) </>= strategies:
//
//    WHERE code >= range_lower('SW1') AND code < range_upper('SW1')
//
// range_lower() is just the fragment's own parsed value -- postcode_parse
// already leaves every unspecified trailing field zeroed. range_upper()
// is the smallest value strictly greater than every value matching the
// fragment: add one at the bit position immediately above whichever
// field postcode_free_bits() says is the first absent one, mirroring
// postcode_mask()'s own field-by-field logic exactly so this can't drift
// out of sync with how % itself decides what "matches this fragment"
// means. Both raise an error for a malformed fragment rather than
// silently returning a value, unlike %/!% -- these are meant to be
// called with a literal, known-good fragment when constructing a query.
//
// As of 1.3.3, both returned values are real, valid, renderable
// postcodes -- not the raw partial bit pattern this used to return for
// any fragment shorter than a full 7-character code. postcode_fill_boundary()
// (just below, alongside postcode_mask()/postcode_free_bits() -- the two
// functions this one is derived from and has to stay consistent with)
// raises sector/walk1/walk2 from "unset" (0) to their real
// minimum (1, ie the digit/letter 'A') wherever the free-bits computation
// above left them unset, AFTER that computation, never before -- which
// field is "the first absent one" has to be decided from the fragment's
// own raw parse, not from a value that's already had absent fields
// filled in, or the boundary would land in the wrong place entirely.
// Only ever raises a field, never lowers one, so it can only move a
// boundary up towards (never past) the nearest real value on that side:
// range_lower(X)'s filled result is still <= every value matching X
// (the true minimum, since sector/walk's real minimum IS 1, not 0), and
// range_upper(X)'s filled result is still the exact value of
// range_lower(Y) for whichever fragment Y turns out to immediately
// follow X in sort order -- still a real postcode itself, still strictly
// greater than every value matching X, so the half-open interval
// `code >= range_lower(X) AND code < range_upper(X)` stays exactly as
// correct as it was with the old unfilled values, just now with both
// ends actually displayable. district2 is deliberately never touched by
// the fill -- its "absent" state is itself a real, meaningful encoding
// (a single-digit district, eg "LS1"), not a gap the way sector/walk's
// zero state is; filling it in would silently change which postcodes
// the fragment matches, not just how the boundary renders (would turn
// "LS1" into "LS10").
//
// One field this doesn't reach: if range_upper() free_bits==0 (a full
// code) and that code's own walk2 is already at its max ('Z'), +1
// overflows walk2 out of its valid range with nothing left to carry
// into -- the pre-existing, already-documented edge case immediately
// below. Full carry propagation across every field was judged out of
// scope for this pass; postcode_render()'s '?' fallback (1.3.3, see
// binfmt.c) still renders that one specific case gracefully rather than
// raising, same as it does for any other invalid field.
//
// Confirmed live: range_upper() on a full code ending in a walk letter of
// 'Z' can even render as a non-alphabetic character (Z's raw value + 1)
// if forced through ::text -- harmless for its actual purpose (comparison
// bounds don't need to look like real postcodes, only sort correctly
// relative to them, which this does).

PG_FUNCTION_INFO_V1(postcode_range_lower);

Datum postcode_range_lower (PG_FUNCTION_ARGS) {
   postcode b = postcode_parse(text_to_cstring(PG_GETARG_TEXT_P(0)), true);
   int free_bits = postcode_free_bits(b);

   if (free_bits < 0)
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("invalid postcode prefix"))));

   PG_RETURN_POSTCODE(postcode_fill_boundary(b));
}


PG_FUNCTION_INFO_V1(postcode_range_upper);

Datum postcode_range_upper (PG_FUNCTION_ARGS) {
   postcode b = postcode_parse(text_to_cstring(PG_GETARG_TEXT_P(0)), true);
   int free_bits = postcode_free_bits(b);

   if (free_bits < 0)
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("invalid postcode prefix"))));

   PG_RETURN_POSTCODE(postcode_fill_boundary(b + (1u << free_bits)));
}


PG_FUNCTION_INFO_V1(postcode_to_char);

Datum postcode_to_char (PG_FUNCTION_ARGS) {
   postcode p = PG_GETARG_POSTCODE(0);
   text  *txt = PG_GETARG_TEXT_P(1);
   char  *str = VARDATA(txt);
   size_t len = VARSIZE(txt) - VARHDRSZ;

   // each template pattern expands to a maximum of two characters
   if (len >= SIZE_MAX/2)
      ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                      errmsg (_("template argument too long"))));

   char *buf = palloc(len*2 + 1);
   char *b = buf;

   // Per-field, same as postcode_render() (see its comment in
   // binfmt.c): a field that isn't valid/renderable becomes '?' rather
   // than requiring a full postcode_binchk() pass up front -- was the
   // same "range_lower()/range_upper() can't be converted to text"
   // problem ::text had, just via to_char() instead. district2==0
   // (absent) still correctly writes nothing, same as always.
   for (size_t i = 0; i != len; i++) {
      switch (str[i]) {
         case 'A':
            if (valid_area(p)) WRITE_AREA(b, p);
            else                *(b++) = '?';
            break;

         case 'D':
            *(b++) = valid_district1(p) ? GET_DISTRICT1(p) + 47 : '?';
            if (GET_DISTRICT2(p))
               *(b++) = valid_district2(p) ? GET_DISTRICT2(p) + 47 : '?';
            break;

         case 'S':
            *(b++) = valid_sector(p) ? GET_SECTOR(p) + 47 : '?';
            break;

         case 'W':
            *(b++) = valid_walk1(p) ? GET_WALK1(p) + 64 : '?';
            *(b++) = valid_walk2(p) ? GET_WALK2(p) + 64 : '?';
            break;

        default: *(b++) = str[i];
      }
   }
   *b = '\0';

   PG_RETURN_TEXT_P(cstring_to_text(buf));
}


PG_FUNCTION_INFO_V1(postcode_to_text);

Datum postcode_to_text (PG_FUNCTION_ARGS) {
   postcode p = PG_GETARG_POSTCODE(0);

   if (! postcode_binchk(p))
      PG_RETURN_NULL();

   char str[9];
   postcode_render(p, str);
   PG_RETURN_TEXT_P(cstring_to_text(str));
}


PG_FUNCTION_INFO_V1(text_to_postcode);

Datum text_to_postcode (PG_FUNCTION_ARGS) {
   postcode p = postcode_parse(text_to_cstring(PG_GETARG_TEXT_P(0)), false);

   if (p == 0)
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("cannot parse input for type postcode"))));

   PG_RETURN_POSTCODE(p);
}


PG_FUNCTION_INFO_V1(dps_in);

Datum dps_in (PG_FUNCTION_ARGS) {
   dps d = postcode_dps_parse(PG_GETARG_CSTRING(0));

   if (d == 0)
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("cannot parse input for type dps"))));

   PG_RETURN_DPS(d);
}


PG_FUNCTION_INFO_V1(dps_out);

Datum dps_out (PG_FUNCTION_ARGS) {
   dps d = PG_GETARG_DPS(0);

   if (! postcode_dps_binchk(d))
      ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
                      errmsg (_("cannot render corrupted binary data to text"))));

   char *str = palloc(3);
   postcode_dps_render(d, str);
   PG_RETURN_CSTRING(str);
}


PG_FUNCTION_INFO_V1(dps_recv);

Datum dps_recv (PG_FUNCTION_ARGS) {
   dps d = pq_getmsgint((StringInfo) PG_GETARG_POINTER(0), sizeof(dps));

   if (! postcode_dps_binchk(d))
      ereport(ERROR, (errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
                      errmsg (_("received binary data is invalid for type dps")),
                      errhint(_("server binary format version is %s"), STR(EXTVERSION))));

   PG_RETURN_DPS(d);
}


PG_FUNCTION_INFO_V1(dps_send);

Datum dps_send (PG_FUNCTION_ARGS) {
   StringInfoData b;
   pq_begintypsend(&b);
   pq_sendint(&b, PG_GETARG_DPS(0), sizeof(dps));
   PG_RETURN_BYTEA_P(pq_endtypsend(&b));
}


PG_FUNCTION_INFO_V1(dps_validate);

Datum dps_validate (PG_FUNCTION_ARGS) {
   dps d = postcode_dps_parse(text_to_cstring(PG_GETARG_TEXT_P(0)));
   PG_RETURN_BOOL(d ? TRUE : FALSE);
}


PG_FUNCTION_INFO_V1(dps_cmp);

Datum dps_cmp (PG_FUNCTION_ARGS) {
   dps a = PG_GETARG_DPS(0),
       b = PG_GETARG_DPS(1);

   if (a == b) PG_RETURN_INT32( 0);
   if (a >  b) PG_RETURN_INT32( 1);
   else        PG_RETURN_INT32(-1);
}


PG_FUNCTION_INFO_V1(dps_eq);

Datum dps_eq (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_DPS(0) == PG_GETARG_DPS(1));
}


PG_FUNCTION_INFO_V1(dps_ne);

Datum dps_ne (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_DPS(0) != PG_GETARG_DPS(1));
}


PG_FUNCTION_INFO_V1(dps_lt);

Datum dps_lt (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_DPS(0) < PG_GETARG_DPS(1));
}


PG_FUNCTION_INFO_V1(dps_gt);

Datum dps_gt (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_DPS(0) > PG_GETARG_DPS(1));
}


PG_FUNCTION_INFO_V1(dps_lte);

Datum dps_lte (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_DPS(0) <= PG_GETARG_DPS(1));
}


PG_FUNCTION_INFO_V1(dps_gte);

Datum dps_gte (PG_FUNCTION_ARGS) {
   PG_RETURN_BOOL(PG_GETARG_DPS(0) >= PG_GETARG_DPS(1));
}


PG_FUNCTION_INFO_V1(dps_to_text);

Datum dps_to_text (PG_FUNCTION_ARGS) {
   dps d = PG_GETARG_DPS(0);

   if (! postcode_dps_binchk(d))
      PG_RETURN_NULL();

   char str[3];

   if (postcode_dps_render(d, str) == 0)
      ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
                      errmsg (_("cannot render corrupted binary data to text"))));

   PG_RETURN_TEXT_P(cstring_to_text(str));
}


PG_FUNCTION_INFO_V1(text_to_dps);

Datum text_to_dps (PG_FUNCTION_ARGS) {
   dps d = postcode_dps_parse(text_to_cstring(PG_GETARG_TEXT_P(0)));

   if (d == 0)
      ereport(ERROR, (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                      errmsg (_("cannot parse input for type dps"))));

   PG_RETURN_DPS(d);
}
