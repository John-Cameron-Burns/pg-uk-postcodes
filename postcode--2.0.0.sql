CREATE TYPE postcode;

CREATE FUNCTION postcode_in(cstring)
   RETURNS postcode
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postcode_out(postcode)
   RETURNS cstring
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postcode_recv(internal)
   RETURNS postcode
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postcode_send(postcode)
   RETURNS bytea
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE TYPE postcode (
   INPUT    = postcode_in,
   OUTPUT   = postcode_out,
   RECEIVE  = postcode_recv,
   SEND     = postcode_send,
   LIKE     = pg_catalog.int4,
   CATEGORY = 'S'
);

CREATE FUNCTION postcode_validate(text)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postcode_cmp(postcode, postcode)
   RETURNS integer
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postcode_eq(postcode, postcode)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postcode_ne(postcode, postcode)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postcode_lt(postcode, postcode)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postcode_gt(postcode, postcode)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postcode_lte(postcode, postcode)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postcode_gte(postcode, postcode)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postcode_cmp_partial(postcode, text)
   RETURNS integer
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postcode_eq_partial_support(internal)
   RETURNS internal
   AS 'MODULE_PATHNAME'
   LANGUAGE C STRICT;

-- Rewrites `postcode % 'fragment'` into the equivalent range_lower()/
-- range_upper() bounds at plan time, for a plan-time-constant fragment
-- -- see postcode_eq_partial_support()'s own comment in postcode.c.
CREATE FUNCTION postcode_eq_partial(postcode, text)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT
   SUPPORT postcode_eq_partial_support;

CREATE FUNCTION postcode_ne_partial(postcode, text)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION range_lower(text)
   RETURNS postcode
   AS 'MODULE_PATHNAME', 'postcode_range_lower'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION range_upper(text)
   RETURNS postcode
   AS 'MODULE_PATHNAME', 'postcode_range_upper'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION to_char(postcode, text)
   RETURNS text
   AS 'MODULE_PATHNAME', 'postcode_to_char'
   LANGUAGE C IMMUTABLE STRICT;

-- Real cast entries, not just the implicit ::text/::postcode I/O
-- fallback every type gets for free -- see this version's own upgrade
-- script (postcode--1.3.2--1.3.3.sql) for why that fallback isn't
-- enough for some internal machinery (ALTER COLUMN TYPE's automatic
-- dependent-index rewrite), and for why AS text is IMPLICIT while
-- AS <type> stays ASSIGNMENT -- that asymmetry is deliberate, not a
-- typo (confirmed live: ASSIGNMENT alone doesn't actually fix the
-- ALTER COLUMN TYPE case, since it's never applied during ordinary
-- function-argument resolution, only IMPLICIT is). Behaviour unchanged
-- either direction beyond that: exactly what postcode_out()/
-- postcode_in() already did.
CREATE FUNCTION postcode_to_text(postcode)
   RETURNS text
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION text_to_postcode(text)
   RETURNS postcode
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE CAST (postcode AS text)
   WITH FUNCTION postcode_to_text(postcode)
   AS IMPLICIT;

CREATE CAST (text AS postcode)
   WITH FUNCTION text_to_postcode(text)
   AS ASSIGNMENT;

CREATE OPERATOR = (
   PROCEDURE  = postcode_eq,
   LEFTARG    = postcode,
   RIGHTARG   = postcode,
   COMMUTATOR = =,
   NEGATOR    = <>,
   RESTRICT   = eqsel,
   JOIN       = eqjoinsel);

CREATE OPERATOR <> (
   PROCEDURE  = postcode_ne,
   LEFTARG    = postcode,
   RIGHTARG   = postcode,
   COMMUTATOR = <>,
   NEGATOR    = =,
   RESTRICT   = neqsel,
   JOIN       = neqjoinsel);

-- RESTRICT/JOIN: PostgreSQL's own standard scalar-comparison estimators
-- (used by int4/text/date/... for the same operators), not anything
-- custom -- postcode is LIKE = pg_catalog.int4, so ANALYZE already
-- collects a compatible histogram for it. Without these, the planner
-- has no way to use that histogram for a </<=/>/>=/BETWEEN predicate at
-- all and falls back to a fixed default guess regardless of how
-- accurate the table's real statistics are -- see this version's own
-- upgrade script (postcode--1.3.3--1.3.4.sql) for the live symptom this
-- was found from.
CREATE OPERATOR < (
   PROCEDURE  = postcode_lt,
   LEFTARG    = postcode,
   RIGHTARG   = postcode,
   COMMUTATOR = >,
   NEGATOR    = >=,
   RESTRICT   = scalarltsel,
   JOIN       = scalarltjoinsel);

CREATE OPERATOR > (
   PROCEDURE  = postcode_gt,
   LEFTARG    = postcode,
   RIGHTARG   = postcode,
   COMMUTATOR = <,
   NEGATOR    = <=,
   RESTRICT   = scalargtsel,
   JOIN       = scalargtjoinsel);

CREATE OPERATOR <= (
   PROCEDURE  = postcode_lte,
   LEFTARG    = postcode,
   RIGHTARG   = postcode,
   COMMUTATOR = >=,
   NEGATOR    = >,
   RESTRICT   = scalarlesel,
   JOIN       = scalarlejoinsel);

CREATE OPERATOR >= (
   PROCEDURE  = postcode_gte,
   LEFTARG    = postcode,
   RIGHTARG   = postcode,
   COMMUTATOR = <=,
   NEGATOR    = <,
   RESTRICT   = scalargesel,
   JOIN       = scalargejoinsel);

CREATE OPERATOR % (
   PROCEDURE  = postcode_eq_partial,
   LEFTARG    = postcode,
   RIGHTARG   = text,
   NEGATOR    = !%,
   RESTRICT   = eqsel,
   JOIN       = eqjoinsel
);

CREATE OPERATOR !% (
   PROCEDURE  = postcode_ne_partial,
   LEFTARG    = postcode,
   RIGHTARG   = text,
   NEGATOR    = %,
   RESTRICT   = neqsel,
   JOIN       = neqjoinsel
);

CREATE OPERATOR FAMILY postcode_ops USING btree;

CREATE OPERATOR CLASS postcode_ops
DEFAULT FOR TYPE postcode USING btree FAMILY postcode_ops AS
   OPERATOR 1 <,
   OPERATOR 2 <=,
   OPERATOR 3 =,
   OPERATOR 4 >=,
   OPERATOR 5 >,
   FUNCTION 1 postcode_cmp(postcode, postcode);

-- 1.3.0 registered % (partial match) at btree strategy 3 here, which is
-- reserved for true equality -- btree relies on strategy-3 matches being
-- reflexive/interchangeable (skip-scan, dedup), which a partial match
-- isn't. That's the root cause of upstream issue #3 ("Use of indexes
-- with % operator produces incorrect results"): queries using % return
-- wrong results whenever a btree index exists on the postcode column.
-- Deliberately not re-registering it here (and dropping the FUNCTION 1
-- entry that only existed to back it, which is otherwise unreachable
-- without a matching operator) -- % still works correctly as a plain
-- function call (postcode_eq_partial), just without index support, i.e.
-- a sequential scan instead of a fast-but-wrong one.


CREATE TYPE dps;

CREATE FUNCTION dps_in(cstring)
   RETURNS dps
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION dps_out(dps)
   RETURNS cstring
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION dps_recv(internal)
   RETURNS dps
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION dps_send(dps)
   RETURNS bytea
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE TYPE dps (
   INPUT          = dps_in,
   OUTPUT         = dps_out,
   RECEIVE        = dps_recv,
   SEND           = dps_send,
   CATEGORY       = 'S',
   INTERNALLENGTH = 1,
   ALIGNMENT      = char,
   PASSEDBYVALUE
);

CREATE FUNCTION dps_validate(text)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION dps_cmp(dps, dps)
   RETURNS integer
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION dps_eq(dps, dps)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION dps_ne(dps, dps)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION dps_lt(dps, dps)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION dps_gt(dps, dps)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION dps_lte(dps, dps)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION dps_gte(dps, dps)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION dps_to_text(dps)
   RETURNS text
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION text_to_dps(text)
   RETURNS dps
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE CAST (dps AS text)
   WITH FUNCTION dps_to_text(dps)
   AS IMPLICIT;

CREATE CAST (text AS dps)
   WITH FUNCTION text_to_dps(text)
   AS ASSIGNMENT;

CREATE OPERATOR = (
   PROCEDURE  = dps_eq,
   LEFTARG    = dps,
   RIGHTARG   = dps,
   COMMUTATOR = =,
   NEGATOR    = <>,
   RESTRICT   = eqsel,
   JOIN       = eqjoinsel);

CREATE OPERATOR <> (
   PROCEDURE  = dps_ne,
   LEFTARG    = dps,
   RIGHTARG   = dps,
   COMMUTATOR = <>,
   NEGATOR    = =,
   RESTRICT   = neqsel,
   JOIN       = neqjoinsel);

CREATE OPERATOR < (
   PROCEDURE  = dps_lt,
   LEFTARG    = dps,
   RIGHTARG   = dps,
   COMMUTATOR = >,
   NEGATOR    = >=,
   RESTRICT   = scalarltsel,
   JOIN       = scalarltjoinsel);

CREATE OPERATOR > (
   PROCEDURE  = dps_gt,
   LEFTARG    = dps,
   RIGHTARG   = dps,
   COMMUTATOR = <,
   NEGATOR    = <=,
   RESTRICT   = scalargtsel,
   JOIN       = scalargtjoinsel);

CREATE OPERATOR <= (
   PROCEDURE  = dps_lte,
   LEFTARG    = dps,
   RIGHTARG   = dps,
   COMMUTATOR = >=,
   NEGATOR    = >,
   RESTRICT   = scalarlesel,
   JOIN       = scalarlejoinsel);

CREATE OPERATOR >= (
   PROCEDURE  = dps_gte,
   LEFTARG    = dps,
   RIGHTARG   = dps,
   COMMUTATOR = <=,
   NEGATOR    = <,
   RESTRICT   = scalargesel,
   JOIN       = scalargejoinsel);

CREATE OPERATOR FAMILY dps_ops USING btree;

CREATE OPERATOR CLASS dps_ops
DEFAULT FOR TYPE dps USING btree FAMILY dps_ops AS
   OPERATOR 1 <,
   OPERATOR 2 <=,
   OPERATOR 3 =,
   OPERATOR 4 >=,
   OPERATOR 5 >,
   FUNCTION 1 dps_cmp(dps, dps);


-- postal_code additions (2.0.0) -- see postcode--1.3.5--2.0.0.sql for the standalone
-- upgrade version of this section, with its own full explanatory comment.

CREATE TYPE postal_code;

CREATE FUNCTION postal_code_in(cstring)
   RETURNS postal_code
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postal_code_out(postal_code)
   RETURNS cstring
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postal_code_recv(internal)
   RETURNS postal_code
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postal_code_send(postal_code)
   RETURNS bytea
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE TYPE postal_code (
   INPUT    = postal_code_in,
   OUTPUT   = postal_code_out,
   RECEIVE  = postal_code_recv,
   SEND     = postal_code_send,
   LIKE     = pg_catalog.int8,
   CATEGORY = 'S'
);

CREATE FUNCTION postal_code_cmp(postal_code, postal_code)
   RETURNS integer
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postal_code_eq(postal_code, postal_code)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postal_code_ne(postal_code, postal_code)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postal_code_lt(postal_code, postal_code)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postal_code_gt(postal_code, postal_code)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postal_code_lte(postal_code, postal_code)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postal_code_gte(postal_code, postal_code)
   RETURNS boolean
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE OPERATOR = (
   PROCEDURE  = postal_code_eq,
   LEFTARG    = postal_code,
   RIGHTARG   = postal_code,
   COMMUTATOR = =,
   NEGATOR    = <>,
   RESTRICT   = eqsel,
   JOIN       = eqjoinsel);

CREATE OPERATOR <> (
   PROCEDURE  = postal_code_ne,
   LEFTARG    = postal_code,
   RIGHTARG   = postal_code,
   COMMUTATOR = <>,
   NEGATOR    = =,
   RESTRICT   = neqsel,
   JOIN       = neqjoinsel);

CREATE OPERATOR < (
   PROCEDURE  = postal_code_lt,
   LEFTARG    = postal_code,
   RIGHTARG   = postal_code,
   COMMUTATOR = >,
   NEGATOR    = >=);

CREATE OPERATOR > (
   PROCEDURE  = postal_code_gt,
   LEFTARG    = postal_code,
   RIGHTARG   = postal_code,
   COMMUTATOR = <,
   NEGATOR    = <=);

CREATE OPERATOR <= (
   PROCEDURE  = postal_code_lte,
   LEFTARG    = postal_code,
   RIGHTARG   = postal_code,
   COMMUTATOR = >=,
   NEGATOR    = >);

CREATE OPERATOR >= (
   PROCEDURE  = postal_code_gte,
   LEFTARG    = postal_code,
   RIGHTARG   = postal_code,
   COMMUTATOR = <=,
   NEGATOR    = <);

CREATE OPERATOR FAMILY postal_code_ops USING btree;

CREATE OPERATOR CLASS postal_code_ops
DEFAULT FOR TYPE postal_code USING btree FAMILY postal_code_ops AS
   OPERATOR 1 <,
   OPERATOR 2 <=,
   OPERATOR 3 =,
   OPERATOR 4 >=,
   OPERATOR 5 >,
   FUNCTION 1 postal_code_cmp(postal_code, postal_code);

-- Two-argument constructor for callers that already have country
-- and national code as separate values, e.g.
--   SELECT postal_code(country_col, zip_col) FROM addresses;
-- analogous to PostGIS's ST_GeomFromText(wkt, srid).
CREATE FUNCTION postal_code(text, text)
   RETURNS postal_code
   AS 'MODULE_PATHNAME', 'postal_code_from_parts'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION country(postal_code)
   RETURNS text
   AS 'MODULE_PATHNAME', 'postal_code_country'
   LANGUAGE C IMMUTABLE STRICT;
