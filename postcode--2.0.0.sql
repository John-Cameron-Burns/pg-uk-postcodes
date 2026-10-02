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

-- STABLE, not IMMUTABLE: parsing depends on postal_code_country_formats
-- (below), which add_country_format()/remove_country_format() let
-- change without a rebuild -- the same input text can legitimately
-- parse to a different value after a reassignment. IMMUTABLE would
-- wrongly license the planner to constant-fold this across statements,
-- or to treat an index on an expression using it as never needing a
-- rebuild after such a reassignment.
CREATE FUNCTION postal_code_in(cstring)
   RETURNS postal_code
   AS 'MODULE_PATHNAME'
   LANGUAGE C STABLE STRICT;

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

-- RESTRICT/JOIN on the inequality operators: PostgreSQL's own standard
-- scalar-comparison estimators, the ones int4/text/date use. Without them
-- the planner can't use ANALYZE's column statistics for a range predicate
-- at all and falls back to a fixed guess -- measured on 148k real rows, a
-- range containing exactly 1 row was estimated at 36,996 (25% of the table)
-- and planned as a bitmap heap scan instead of an index-only scan. The UK
-- postcode type had the same omission until 1.3.4 (39s -> 270ms there).
-- Anything built on ranges (partial match, upper_bound()) depends on this.
CREATE OPERATOR < (
   PROCEDURE  = postal_code_lt,
   LEFTARG    = postal_code,
   RIGHTARG   = postal_code,
   COMMUTATOR = >,
   NEGATOR    = >=,
   RESTRICT   = scalarltsel,
   JOIN       = scalarltjoinsel);

CREATE OPERATOR > (
   PROCEDURE  = postal_code_gt,
   LEFTARG    = postal_code,
   RIGHTARG   = postal_code,
   COMMUTATOR = <,
   NEGATOR    = <=,
   RESTRICT   = scalargtsel,
   JOIN       = scalargtjoinsel);

CREATE OPERATOR <= (
   PROCEDURE  = postal_code_lte,
   LEFTARG    = postal_code,
   RIGHTARG   = postal_code,
   COMMUTATOR = >=,
   NEGATOR    = >,
   RESTRICT   = scalarlesel,
   JOIN       = scalarlejoinsel);

CREATE OPERATOR >= (
   PROCEDURE  = postal_code_gte,
   LEFTARG    = postal_code,
   RIGHTARG   = postal_code,
   COMMUTATOR = <=,
   NEGATOR    = <,
   RESTRICT   = scalargesel,
   JOIN       = scalargejoinsel);

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
-- analogous to PostGIS's ST_GeomFromText(wkt, srid). STABLE, not
-- IMMUTABLE -- same reasoning as postal_code_in above.
CREATE FUNCTION postal_code(text, text)
   RETURNS postal_code
   AS 'MODULE_PATHNAME', 'postal_code_from_parts'
   LANGUAGE C STABLE STRICT;

-- NULL-returning counterpart of postal_code(cc, code), for loading feeds
-- that contain rows which aren't valid postcodes (the role topostcode()
-- plays for the UK type): a bad or unassigned country, or a national code
-- that doesn't parse, gives NULL instead of an error that aborts the whole
-- COPY/INSERT. Strict parsing stays the default; this is opt-in by name.
-- Two forms, mirroring the strict ones:
--   to_postal_code('FR-75054 CEDEX 01')   -- like ::postal_code
--   to_postal_code('FR', '75054 CEDEX 01') -- like postal_code(cc, code)
CREATE FUNCTION to_postal_code(text)
   RETURNS postal_code
   AS 'MODULE_PATHNAME', 'postal_code_lenient_text'
   LANGUAGE C STABLE STRICT;

CREATE FUNCTION to_postal_code(text, text)
   RETURNS postal_code
   AS 'MODULE_PATHNAME', 'postal_code_lenient'
   LANGUAGE C STABLE STRICT;

-- is_valid(): does this text parse as a postal_code at all? Never raises
-- for bad input (false), NULL in gives NULL out (so it works in a CHECK
-- constraint). Same two forms as the constructors:
--   is_valid('FR-75054 CEDEX 01')    is_valid('FR', '75054 CEDEX 01')
-- It is exactly "to_postal_code(...) IS NOT NULL" -- every per-country
-- restriction (Canadian excluded letters, Eircode's alphabet, ZIP+4 0000,
-- ...) is enforced by the same parser that enforces it at ingest, so the
-- two can't disagree. A country assigned to a format this build doesn't
-- have is a configuration fault and still raises rather than saying false.
CREATE FUNCTION is_valid(text)
   RETURNS boolean
   LANGUAGE sql STABLE STRICT
   AS 'SELECT to_postal_code($1) IS NOT NULL';

CREATE FUNCTION is_valid(text, text)
   RETURNS boolean
   LANGUAGE sql STABLE STRICT
   AS 'SELECT to_postal_code($1, $2) IS NOT NULL';

CREATE FUNCTION country(postal_code)
   RETURNS text
   AS 'MODULE_PATHNAME', 'postal_code_country'
   LANGUAGE C IMMUTABLE STRICT;


-- Which country currently maps to which format, kept as real SQL
-- tables rather than compiled into postal_code_fmt.c, specifically so
-- assigning a country to a format that already exists (e.g. a second
-- plain-5-digit country joining FR/CZ) needs a row insert, not a
-- rebuild -- only a genuinely new format (new digit/letter grouping,
-- new exclusion rules, ...) still needs real C and a new extension
-- version. postal_code_in()/postal_code(text,text) look this up via
-- SPI on every call (postal_code_country.c) -- deliberately not
-- cached in the backend, so a reassignment is visible immediately to
-- every session without needing a manual refresh/reconnect.

CREATE TABLE postal_code_formats (
   name        text PRIMARY KEY,
   description text NOT NULL
);
COMMENT ON TABLE postal_code_formats IS
   'One row per postal_code format actually compiled into this extension (pc_formats[] in postal_code_fmt.c) -- a row here with no matching C encoder does nothing. Exists so postal_code_country_formats has something real to reference via foreign key, and so SELECT * FROM postal_code_formats is a live list of what''s available. Maintained by this extension''s own upgrade scripts; not meant for ad hoc editing.';

INSERT INTO postal_code_formats (name, description) VALUES
   ('US', 'United States: ZIP5 + optional ZIP+4'),
   ('CA', 'Canada: FSA, optionally with a full LDU'),
   ('FR', 'France: 5 digits'),
   ('BR', 'Brazil: 5-digit base + optional 3-digit suffix (CEP)'),
   ('CZ', 'Czech Republic: 5 digits, rendered "NNN NN"'),
   ('LU', 'Luxembourg: "L-" + 4 digits'),
   ('GB', 'United Kingdom: wraps the postcode type''s 32-bit layout; the outcode alone is a valid value'),
   ('IE', 'Ireland: Eircode routing key, optionally with the 4-character unique identifier');

CREATE TABLE postal_code_country_formats (
   iso2        text PRIMARY KEY CHECK (iso2 ~ '^[A-Z]{2}$'),
   format_name text NOT NULL REFERENCES postal_code_formats(name),
   assigned_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE postal_code_country_formats IS
   'Which format a given ISO 3166-1 alpha-2 country currently uses for NEW postal_code values -- see add_country_format()/remove_country_format(). Decoding an existing stored value never consults this table: the format is already in the value''s own bits (see postal_code_fmt.h), so reassigning a country here has no effect on postal_code values already written under its old format.';

INSERT INTO postal_code_country_formats (iso2, format_name) VALUES
   ('BR', 'BR'), ('CA', 'CA'), ('CZ', 'CZ'), ('FR', 'FR'), ('LU', 'LU'), ('US', 'US'),
   -- the Crown Dependencies' areas (GY, IM, JE) are already part of the UK layout
   ('GB', 'GB'), ('GG', 'GB'), ('IM', 'GB'), ('JE', 'GB'),
   ('IE', 'IE');

CREATE FUNCTION add_country_format(cc text, format_name text)
   RETURNS void
   LANGUAGE plpgsql AS $$
DECLARE
   norm_cc text := upper(cc);
BEGIN
   IF norm_cc !~ '^[A-Z]{2}$' THEN
      RAISE EXCEPTION 'country code must be exactly two letters, got %', cc;
   END IF;
   IF NOT EXISTS (SELECT 1 FROM postal_code_formats WHERE name = format_name) THEN
      RAISE EXCEPTION 'unknown postal_code format %, must be one of: %',
         format_name, (SELECT string_agg(name, ', ' ORDER BY name) FROM postal_code_formats);
   END IF;
   INSERT INTO postal_code_country_formats (iso2, format_name)
   VALUES (norm_cc, format_name)
   ON CONFLICT (iso2) DO UPDATE SET format_name = EXCLUDED.format_name, assigned_at = now();
END;
$$;
COMMENT ON FUNCTION add_country_format(text, text) IS
   'Assign (or reassign) a country to an already-implemented postal_code format, e.g. add_country_format(''DE'', ''FR'') if Germany ever needed the same plain-5-digit shape. Does NOT create new formats -- format_name must already exist in postal_code_formats (i.e. have real C behind it); see this extension''s README for what''s currently implemented.';

CREATE FUNCTION remove_country_format(cc text)
   RETURNS void
   LANGUAGE plpgsql AS $$
BEGIN
   DELETE FROM postal_code_country_formats WHERE iso2 = upper(cc);
END;
$$;
COMMENT ON FUNCTION remove_country_format(text) IS
   'Undo add_country_format(): after this, parsing "CC-..."/postal_code(cc, ...) for that country raises rather than resolving to whatever format it used to have. Existing stored values for that country are unaffected -- see postal_code_country_formats'' own comment.';
