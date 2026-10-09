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


-- postal_code additions (2.0.1) -- see postcode--1.3.5--2.0.1.sql for the standalone
-- upgrade version of this section, with its own full explanatory comment.

CREATE TYPE postal_code;

-- STABLE, not IMMUTABLE: parsing depends on postal_code_country_formats
-- (below), which add_country_format()/remove_country_format() let
-- change without a rebuild -- the same input text can legitimately
-- parse to a different value after a reassignment. IMMUTABLE would
-- wrongly license the planner to constant-fold this across statements,
-- or to treat an index on an expression using it as never needing a
-- rebuild after such a reassignment.
--
-- The 3-argument form of an input function receives the column's type modifier
-- (see the country lock, below); the same goes for receive.
CREATE FUNCTION postal_code_in(cstring, oid, integer)
   RETURNS postal_code
   AS 'MODULE_PATHNAME'
   LANGUAGE C STABLE STRICT;

CREATE FUNCTION postal_code_out(postal_code)
   RETURNS cstring
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postal_code_recv(internal, oid, integer)
   RETURNS postal_code
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postal_code_send(postal_code)
   RETURNS bytea
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postal_code_typmod_in(cstring[])
   RETURNS integer
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION postal_code_typmod_out(integer)
   RETURNS cstring
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE TYPE postal_code (
   INPUT    = postal_code_in,
   OUTPUT   = postal_code_out,
   RECEIVE  = postal_code_recv,
   SEND     = postal_code_send,
   TYPMOD_IN  = postal_code_typmod_in,
   TYPMOD_OUT = postal_code_typmod_out,
   LIKE     = pg_catalog.int8,
   CATEGORY = 'S'
);

-- The country lock. A column declared postal_code('US') only accepts US
-- postal codes, the way PostGIS locks a geometry column to an SRID with
-- geometry(Point, 4326): the type modifier is the country, enforced on
-- INSERT/UPDATE, on COPY (text and binary) and on ::postal_code('US') casts.
-- A locked column also accepts the bare national code, since it already knows
-- the country: '90210' goes into a postal_code('US') column as US-90210. An
-- unlocked column still requires the CC- prefix. Quote the code ('IN' and 'TO'
-- are SQL keywords). postal_code_columns, below, shows which columns are locked.
--
-- This does not lock the FORMAT, only the country (a country that moves to a
-- new format keeps working in its column), and it is enforced only where a
-- value is assigned or cast, as with any type modifier -- a value merely
-- returned from a function is not re-checked.
CREATE FUNCTION postal_code_enforce(postal_code, integer, boolean)
   RETURNS postal_code
   AS 'MODULE_PATHNAME'
   LANGUAGE C IMMUTABLE STRICT;

CREATE CAST (postal_code AS postal_code)
   WITH FUNCTION postal_code_enforce(postal_code, integer, boolean)
   AS IMPLICIT;

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

-- postal_code(postcode, cc): the constructor for callers that have the national
-- code and the country as separate values, analogous to PostGIS's
-- ST_GeomFromText(wkt, srid) -- or a "CC-code" string that may also have a
-- separate country column to cross-check against:
--   postal_code('90210-1234', 'US')    the country comes from cc
--   postal_code('US-90210-1234', NULL) ... or from the prefix, cc may be NULL
--   postal_code('US-90210-1234', 'US') ... or both, which must agree
--   postal_code('US-90210', 'CA')      ERROR: they disagree
--   postal_code('90210', NULL)         ERROR: no country at all
-- "Has a prefix" means exactly two letters then a hyphen, which no national
-- format starts with. STABLE, not IMMUTABLE, like postal_code_in. Not STRICT:
-- a NULL cc is meaningful. A NULL postcode gives NULL.
CREATE FUNCTION postal_code(postcode text, cc text)
   RETURNS postal_code
   AS 'MODULE_PATHNAME', 'postal_code_from_parts'
   LANGUAGE C STABLE;

-- NULL-returning counterparts of the strict constructors, for loading feeds
-- that contain rows which aren't valid postcodes (the role topostcode()
-- plays for the UK type): anything that would make the strict form raise as
-- bad input -- no country, a country that disagrees with the prefix, an
-- unassigned country, a national code that doesn't parse -- gives NULL
-- instead of an error that aborts the whole COPY/INSERT. Strict parsing
-- stays the default; this is opt-in by name. Two forms, mirroring the strict
-- ones:
--   to_postal_code('FR-75054 CEDEX 01')       -- like ::postal_code
--   to_postal_code('75054 CEDEX 01', 'FR')    -- like postal_code(postcode, cc)
CREATE FUNCTION to_postal_code(text)
   RETURNS postal_code
   AS 'MODULE_PATHNAME', 'postal_code_lenient_text'
   LANGUAGE C STABLE STRICT;

CREATE FUNCTION to_postal_code(postcode text, cc text)
   RETURNS postal_code
   AS 'MODULE_PATHNAME', 'postal_code_lenient'
   LANGUAGE C STABLE;

-- is_valid_postal_code(): does this text parse as a postal_code at all? Never raises
-- for bad input (false); a NULL postcode gives NULL (so it works in a CHECK
-- constraint, which lets NULLs through). One function for both forms of the
-- constructors:
--   is_valid_postal_code('FR-75054 CEDEX 01')    is_valid_postal_code('75054 CEDEX 01', 'FR')
-- It is exactly "to_postal_code(...) IS NOT NULL" -- every per-country
-- restriction (Canadian excluded letters, Eircode's alphabet, ZIP+4 0000,
-- ...) is enforced by the same parser that enforces it at ingest, so the
-- two can't disagree. A country assigned to a format this build doesn't
-- have is a configuration fault and still raises rather than saying false.
--
-- Named for what it validates: 2.0.0 had a bare is_valid(), which collided with the gsscode extension's
-- is_valid(text) in the production IDM database, and is ambiguous for an untyped literal wherever the isn
-- extension (is_valid(isbn), is_valid(ean13), ...) is installed.
CREATE FUNCTION is_valid_postal_code(postcode text, cc text DEFAULT NULL)
   RETURNS boolean
   LANGUAGE sql STABLE
   AS 'SELECT CASE WHEN $1 IS NULL THEN NULL ELSE to_postal_code($1, $2) IS NOT NULL END';

-- Partial match. A fragment is "CC-" plus a PREFIX of the national code --
-- 'GB-LS24', 'FR-75', 'CA-K1A 0' -- and matches every value that starts with
-- it. Each format orders its values exactly as its text sorts, so a prefix
-- is one contiguous range and neighbouring prefixes tile with no gap or
-- overlap. A fragment is not a value: 'FR-75' is a fragment but not a
-- postcode.
--
-- lower_bound(): the smallest valid value in the range (inclusive).
-- upper_bound(): the smallest valid value past it (exclusive) -- a real
--   postcode wherever a successor exists ('CA-K1A' -> 'CA-K1B', skipping
--   letters Canada never uses). Where there is none -- the fragment reaches
--   the top of the country ('US-99', the last UK area) -- it is that
--   country's end-of-country bound, 'US-~': a value that sorts after every
--   real value of the country and before the first of the next. It is a
--   bound, never a postcode (is_valid_postal_code('US-~') is false), and it is what makes
--   `pc < upper_bound(...)` right at the top of a country too.
CREATE FUNCTION lower_bound(text)
   RETURNS postal_code
   AS 'MODULE_PATHNAME', 'postal_code_lower_bound'
   LANGUAGE C STABLE STRICT;

CREATE FUNCTION upper_bound(text)
   RETURNS postal_code
   AS 'MODULE_PATHNAME', 'postal_code_upper_bound'
   LANGUAGE C STABLE STRICT;

-- outcode(): the area part of a postcode, as a complete valid postcode of its
-- own -- outcode('GB-SW1A 1AA') is 'GB-SW1A', a US ZIP+4 gives its ZIP5, a
-- Canadian code its FSA, an Eircode its routing key, a CEP its 5-digit base.
-- It is idempotent (an outcode is its own outcode) and NULL where the format
-- has no distinct outcode -- FR, CZ and LU, where the leading digits are only
-- implicitly one -- or for the end-of-country bound, which isn't a postcode.
-- district() is the same function under its other name.
--
-- IMMUTABLE, unlike postal_code_in: it only reads the value's own bits (the
-- format is stored in them), never the country->format table, so it can be
-- used in an index: CREATE INDEX ON t (outcode(pc)).
CREATE FUNCTION outcode(postal_code)
   RETURNS postal_code
   AS 'MODULE_PATHNAME', 'postal_code_outcode'
   LANGUAGE C IMMUTABLE STRICT;

CREATE FUNCTION district(postal_code)
   RETURNS postal_code
   AS 'MODULE_PATHNAME', 'postal_code_outcode'
   LANGUAGE C IMMUTABLE STRICT;

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
   'The kinds of format a country can be assigned: the encoders compiled into this extension (pc_formats[] in postal_code_fmt.c), and "pattern", meaning the country has a language in postal_code_languages. Exists so postal_code_country_formats has something real to reference via foreign key. Maintained by this extension''s own upgrade scripts; not meant for ad hoc editing.';

INSERT INTO postal_code_formats (name, description) VALUES
   ('US', 'United States: ZIP5 + optional ZIP+4'),
   ('CA', 'Canada: FSA, optionally with a full LDU'),
   ('FR', 'France: 5 digits'),
   ('BR', 'Brazil: 5-digit base + optional 3-digit suffix (CEP)'),
   ('CZ', 'Czech Republic: 5 digits, rendered "NNN NN"'),
   ('LU', 'Luxembourg: "L-" + 4 digits'),
   ('GB', 'United Kingdom: wraps the postcode type''s 32-bit layout; the outcode alone is a valid value'),
   ('IE', 'Ireland: Eircode routing key, optionally with the 4-character unique identifier'),
   ('pattern', 'A pattern: the country''s codes are defined by a regular expression or template in postal_code_languages');

-- Country assignments are split in two so that a dump can carry exactly the
-- ones a user made: postal_code_builtin_countries is what this extension
-- ships (recreated by CREATE EXTENSION, never dumped), postal_code_user_countries
-- is what add_country_format()/add_country_template()/remove_country_format()
-- write (dumped, and restored over the top). postal_code_country_formats is
-- the view everything reads: a user row wins over a built-in one.
CREATE TABLE postal_code_builtin_countries (
   iso2        text PRIMARY KEY CHECK (iso2 ~ '^[A-Z]{2}$'),
   format_name text NOT NULL REFERENCES postal_code_formats(name)
);
COMMENT ON TABLE postal_code_builtin_countries IS
   'The country -> format assignments this extension ships. Not dumped, and not for editing: use add_country_format() / remove_country_format(), which record your change in postal_code_user_countries, or read postal_code_country_formats for the result.';

INSERT INTO postal_code_builtin_countries (iso2, format_name) VALUES
   ('BR', 'BR'), ('CA', 'CA'), ('CZ', 'CZ'), ('FR', 'FR'), ('LU', 'LU'), ('US', 'US'),
   -- the Crown Dependencies' areas (GY, IM, JE) are already part of the UK layout
   ('GB', 'GB'), ('GG', 'GB'), ('IM', 'GB'), ('JE', 'GB'),
   ('IE', 'IE');

-- format_name NULL is a tombstone: "this built-in assignment has been removed".
CREATE TABLE postal_code_user_countries (
   iso2        text PRIMARY KEY CHECK (iso2 ~ '^[A-Z]{2}$'),
   format_name text REFERENCES postal_code_formats(name),
   assigned_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE postal_code_user_countries IS
   'Country -> format assignments made with add_country_format() / add_country_template() / remove_country_format(), on top of postal_code_builtin_countries (a NULL format_name means a built-in assignment was removed). Included in pg_dump, so assignments survive a dump and restore. Edit through the functions, not by hand.';
SELECT pg_extension_config_dump('postal_code_user_countries', '');

CREATE VIEW postal_code_country_formats AS
   SELECT u.iso2, u.format_name, false AS builtin, u.assigned_at
   FROM postal_code_user_countries u
   WHERE u.format_name IS NOT NULL
   UNION ALL
   SELECT b.iso2, b.format_name, true, NULL::timestamptz
   FROM postal_code_builtin_countries b
   WHERE NOT EXISTS (SELECT 1 FROM postal_code_user_countries u WHERE u.iso2 = b.iso2);
COMMENT ON VIEW postal_code_country_formats IS
   'Which format a given ISO 3166-1 alpha-2 country currently uses for NEW postal_code values -- see add_country_format() / add_country_template() / remove_country_format(). Decoding an existing stored value never consults this: the format is already in the value''s own bits (see postal_code_fmt.h), so reassigning a country here has no effect on postal_code values already written under its old format. builtin says whether the assignment ships with the extension or was made by a user.';

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
      RAISE EXCEPTION 'unknown postal_code format %, must be one of: % (or use add_country_template() to define a new one)',
         format_name, (SELECT string_agg(name, ', ' ORDER BY name COLLATE "C") FROM postal_code_formats);
   END IF;
   IF format_name = 'pattern' AND NOT EXISTS (SELECT 1 FROM postal_code_languages WHERE iso2 = norm_cc) THEN
      RAISE EXCEPTION 'country % has no pattern yet: define one with add_country_template(%, ''...'')', norm_cc, quote_literal(norm_cc);
   END IF;
   INSERT INTO postal_code_user_countries (iso2, format_name)
   VALUES (norm_cc, format_name)
   ON CONFLICT (iso2) DO UPDATE SET format_name = EXCLUDED.format_name, assigned_at = now();
END;
$$;
COMMENT ON FUNCTION add_country_format(text, text) IS
   'Assign (or reassign) a country to an already-implemented postal_code format, e.g. add_country_format(''DE'', ''FR'') if Germany ever needed the same plain-5-digit shape. Does NOT create new formats -- format_name must already exist in postal_code_formats (i.e. have real C behind it); see this extension''s README for what''s currently implemented.';

CREATE FUNCTION remove_country_format(cc text)
   RETURNS void
   LANGUAGE plpgsql AS $$
DECLARE
   norm_cc text := upper(cc);
BEGIN
   IF EXISTS (SELECT 1 FROM postal_code_builtin_countries WHERE iso2 = norm_cc) THEN
      -- a shipped assignment can't be deleted, only overridden: leave a tombstone
      INSERT INTO postal_code_user_countries (iso2, format_name) VALUES (norm_cc, NULL)
      ON CONFLICT (iso2) DO UPDATE SET format_name = NULL, assigned_at = now();
   ELSE
      DELETE FROM postal_code_user_countries WHERE iso2 = norm_cc;
   END IF;
END;
$$;
COMMENT ON FUNCTION remove_country_format(text) IS
   'Undo add_country_format(): after this, parsing "CC-..."/postal_code(..., cc) for that country raises rather than resolving to whatever format it used to have. Existing stored values for that country are unaffected -- see postal_code_country_formats'' own comment.';


-- ---- patterns: a country's codes defined by a regular expression -----------------------------
-- A country whose postal codes follow rules can be given a PATTERN, in SQL, with no C and no rebuild:
--
--   SELECT add_country_template('PL', 'NN-NNN');                     -- the short form
--   SELECT add_country_template('NL', '/[1-9]\d{3}( [A-Z]{2})?/');    -- or a regular expression
--
-- The pattern defines the whole, finite set of the country's codes (see postal_code_pattern.h for the
-- syntax), and a code is stored as its RANK among them in text order. So order, prefix ranges and their
-- bounds are exact for any pattern, and a pattern can say what a template cannot: which letters may
-- appear where, several lengths or forms, a fixed prefix, that 0000 is not a code.
--
-- Each country has its own LANGUAGES, numbered from 1; a stored value carries its country and the
-- language's version in its format tag, and is read back through this table. So a language can never
-- change once it exists (the trigger below refuses): to change a country's rules, add a new one. Values
-- already written go on reading as they were written.
CREATE TABLE postal_code_languages (
   iso2       text NOT NULL CHECK (iso2 ~ '^[A-Z]{2}$'),
   version    smallint NOT NULL CHECK (version BETWEEN 1 AND 51),
   source     text NOT NULL,
   pattern    text NOT NULL,
   builtin    boolean NOT NULL DEFAULT false,
   created_at timestamptz NOT NULL DEFAULT now(),
   PRIMARY KEY (iso2, version)
);
COMMENT ON TABLE postal_code_languages IS
   'The pattern each country''s codes are stored under, one row per version (a country''s current language is its highest). source is what was written (a template or /regular expression/); pattern is the regular expression it means, which is what values are decoded with. Rows are permanent: stored values are read through them. Add them with add_country_template(), not by hand. The ones you add are included in pg_dump, because values cannot be read without them; the builtin ones come with the extension.';
SELECT pg_extension_config_dump('postal_code_languages', 'WHERE NOT builtin');

CREATE FUNCTION postal_code_pattern_check(text)
   RETURNS text
   AS 'MODULE_PATHNAME', 'postal_code_pattern_check'
   LANGUAGE C IMMUTABLE STRICT;
COMMENT ON FUNCTION postal_code_pattern_check(text) IS
   'Checks a postal_code template or /regular expression/ and returns the regular expression it means, or raises an error saying what is wrong with it.';

CREATE FUNCTION postal_code_pattern_size(text)
   RETURNS bigint
   AS 'MODULE_PATHNAME', 'postal_code_pattern_size'
   LANGUAGE C IMMUTABLE STRICT;
COMMENT ON FUNCTION postal_code_pattern_size(text) IS
   'How many different codes a postal_code template or /regular expression/ allows (at most 2^48).';

CREATE FUNCTION postal_code_languages_are_permanent()
   RETURNS trigger
   LANGUAGE plpgsql AS $$
BEGIN
   RAISE EXCEPTION 'postal_code_languages rows are permanent: stored postal_code values are decoded with them'
      USING HINT = 'to change a country''s rules, add a new language with add_country_template()';
END;
$$;
CREATE TRIGGER postal_code_languages_permanent_row
   BEFORE UPDATE OR DELETE ON postal_code_languages
   FOR EACH ROW EXECUTE FUNCTION postal_code_languages_are_permanent();
CREATE TRIGGER postal_code_languages_permanent_truncate
   BEFORE TRUNCATE ON postal_code_languages
   FOR EACH STATEMENT EXECUTE FUNCTION postal_code_languages_are_permanent();

CREATE FUNCTION add_country_template(cc text, spec text)
   RETURNS void
   LANGUAGE plpgsql AS $$
DECLARE
   norm_cc text := upper(cc);
   re      text;
   cur     record;
   v       smallint;
BEGIN
   IF norm_cc !~ '^[A-Z]{2}$' THEN
      RAISE EXCEPTION 'country code must be exactly two letters, got %', cc;
   END IF;
   re := postal_code_pattern_check(spec);

   -- one writer at a time, so two sessions cannot be given the same version
   LOCK TABLE postal_code_languages IN SHARE ROW EXCLUSIVE MODE;

   SELECT l.version, l.pattern INTO cur FROM postal_code_languages l WHERE l.iso2 = norm_cc ORDER BY l.version DESC LIMIT 1;
   IF cur.version IS NULL OR cur.pattern <> re THEN
      v := coalesce(cur.version, 0) + 1;
      IF v > 51 THEN
         RAISE EXCEPTION 'country % already has 51 postal_code languages, the most there is room for', norm_cc;
      END IF;
      INSERT INTO postal_code_languages (iso2, version, source, pattern) VALUES (norm_cc, v, spec, re);
   END IF;

   PERFORM add_country_format(norm_cc, 'pattern');
END;
$$;
COMMENT ON FUNCTION add_country_template(text, text) IS
   'Give a country a pattern for its postal codes: add_country_template(''PL'', ''NN-NNN'') or add_country_template(''TW'', ''/\d{3}(-\d{2,3})?/''). A template is N (a digit), A (a letter), X (either), a space or hyphen, and [ ] around an optional part; a regular expression is written between slashes (see postal_code_pattern.h). It defines the whole set of the country''s codes. If the country already has a different pattern this adds a new version of it; values already stored keep the one they were written with.';

-- ---- the world --------------------------------------------------------------
-- Every ISO 3166-1 country and territory, and what is known about its postal
-- codes, so that "no format" is never ambiguous: a country with no assignment
-- either has no postal code system or has not been added.
CREATE TABLE postal_code_iso_countries (
   iso2  text PRIMARY KEY CHECK (iso2 ~ '^[A-Z]{2}$'),
   name  text NOT NULL,
   basis text NOT NULL,
   note  text
);
COMMENT ON TABLE postal_code_iso_countries IS
   'Every ISO 3166-1 country and territory with where its postal code format came from (built in, GeoNames data, Wikipedia''s list of postal codes), or "no postal codes" if it has no system. See the postal_code_world view. Maintained by this extension; the formats themselves are in postal_code_country_formats.';

-- BEGIN generated by tools/world_formats.py -- edit that, not this
-- Each country with a pattern gets its own language, version 1; the stored pattern is worked out by the
-- extension itself (postal_code_pattern_check), from the spec given here.
INSERT INTO postal_code_languages (iso2, version, source, pattern, builtin)
   SELECT iso2, 1, spec, postal_code_pattern_check(spec), true FROM (VALUES
   ('AD', '/[1-7]\d{2}/'),
   ('AE', 'NNNNN[ NNNNN]'),
   ('AF', 'NNNN'),
   ('AI', '/2640/'),
   ('AL', 'NNNN'),
   ('AM', 'NNNN'),
   ('AQ', '/BIQQ 1ZZ/'),
   ('AR', '/([ABCDEFGHJKLMNPQRSTUVWXYZ]\d{4}([A-Z]{3})?|\d{4})/'),
   ('AS', '/96799(-([1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/'),
   ('AT', '/[1-9]\d{3}/'),
   ('AU', 'NNNN'),
   ('AX', '/22\d{3}/'),
   ('AZ', 'NNNN'),
   ('BA', 'NNNNN'),
   ('BB', 'NNNNN'),
   ('BD', '/[1-9]\d{3}/'),
   ('BE', '/[1-9]\d{3}/'),
   ('BG', '/[1-9]\d{3}/'),
   ('BH', 'NNN[N]'),
   ('BM', 'AA XX'),
   ('BN', '/[A-Z]{2}\d{4}/'),
   ('BT', 'NNNNN'),
   ('BY', 'NNNNNN'),
   ('CC', 'NNNN'),
   ('CH', '/[1-9]\d{3}/'),
   ('CL', '/[1-9]\d{2}-\d{4}/'),
   ('CN', 'NNNNNN'),
   ('CO', 'NNNNNN[-NNN]'),
   ('CR', 'NNNNN[-NNNN]'),
   ('CU', '/[1-9]\d{4}/'),
   ('CV', 'NNNN'),
   ('CX', 'NNNN'),
   ('CY', '/[1-9]\d{3}/'),
   ('DE', '/(0[1-9]|[1-9]\d)\d{3}/'),
   ('DK', 'NNNN'),
   ('DO', 'NNNNN'),
   ('DZ', 'NNNNN'),
   ('EC', 'NNNNNN'),
   ('EE', '/[1-9]\d{4}/'),
   ('EG', 'NNNNN[NN]'),
   ('ES', '/(0[1-9]|[1-4]\d|5[0-2])\d{3}/'),
   ('ET', 'NNNN'),
   ('FI', 'NNNNN'),
   ('FK', '/FIQQ 1ZZ/'),
   ('FM', '/9694[1-4](-([1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/'),
   ('FO', '/[1-9]\d{2}/'),
   ('GE', 'NNNN'),
   ('GH', '/[A-Z][A-Z0-9]\d{3,5}/'),
   ('GL', 'NNNN'),
   ('GN', 'NNN'),
   ('GR', '/[1-8]\d{2} \d{2}/'),
   ('GS', '/SIQQ 1ZZ/'),
   ('GT', 'NNNNN'),
   ('GU', '/969\d{2}(-([1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/'),
   ('GW', 'NNNN'),
   ('HK', 'NNNNNN'),
   ('HM', 'NNNN'),
   ('HN', 'NNNNN'),
   ('HR', 'NNNNN'),
   ('HT', 'NNNN'),
   ('HU', '/[1-9]\d{3}/'),
   ('ID', 'NNNNN'),
   ('IL', 'NNNNN[NN]'),
   ('IN', '/[1-9]\d{5}/'),
   ('IO', '/BBND 1ZZ/'),
   ('IQ', 'NNNNN'),
   ('IR', 'NNNNN[-NNNNN]'),
   ('IS', '/[1-9]\d{2}/'),
   ('IT', 'NNNNN'),
   ('JM', 'NN'),
   ('JO', 'NNNNN'),
   ('JP', 'NNN-NNNN'),
   ('KE', 'NNNNN'),
   ('KG', 'NNNNNN'),
   ('KH', 'NNNNN[N]'),
   ('KN', 'NNNN'),
   ('KR', '/(0[1-9]|[1-5]\d|6[0-3])\d{3}/'),
   ('KW', 'NNNNN'),
   ('KY', '/[1-3]-\d{4}/'),
   ('KZ', '/\d{6}|[A-Z]\d\d[A-Z]\d[A-Z]\d/'),
   ('LA', 'NNNNN'),
   ('LB', 'NNNN[ NNNN]'),
   ('LC', 'NN NNN'),
   ('LI', '/94(8[5-9]|9[0-8])/'),
   ('LK', 'NNNNN'),
   ('LR', 'NNNN'),
   ('LS', 'NNN'),
   ('LT', 'NNNNN'),
   ('LV', 'NNNN'),
   ('MA', 'NNNNN'),
   ('MC', '/980\d{2}/'),
   ('MD', 'NNNN'),
   ('ME', 'NNNNN'),
   ('MG', 'NNN'),
   ('MH', '/969[67]\d(-([1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/'),
   ('MK', 'NNNN'),
   ('MM', 'NNNNN[NN]'),
   ('MN', 'NNNNN'),
   ('MO', 'NNNNNN'),
   ('MP', '/9695[0-2](-([1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/'),
   ('MS', '/MSR \d{4}/'),
   ('MT', 'AAA[ NNNN]'),
   ('MU', '/[0-9A-Z]\d{4}/'),
   ('MV', 'NNNNN'),
   ('MW', 'NNNNNN'),
   ('MX', '/(0[1-9]|[1-9]\d)\d{3}/'),
   ('MY', '/(0[1-9]|[1-9]\d)\d{3}/'),
   ('MZ', 'NNNN[-NN]'),
   ('NA', 'NNNNN'),
   ('NE', 'NNNN'),
   ('NF', 'NNNN'),
   ('NG', 'NNNNNN'),
   ('NI', '/[1-9]\d{4}/'),
   ('NL', '/[1-9]\d{3}( ([A-EGHJ-NPRTVWXZ][A-EGHJ-NPRSTVWXZ]|S[BCEGHJ-NPRTVWXZ]))?/'),
   ('NO', 'NNNN'),
   ('NP', 'NNNNN'),
   ('NR', 'AAANN'),
   ('NU', 'NNNN'),
   ('NZ', 'NNNN'),
   ('OM', 'NNN'),
   ('PA', 'NNNN[N]'),
   ('PE', 'NNNNN'),
   ('PG', 'NNN'),
   ('PH', 'NNNN'),
   ('PK', '/[1-9]\d{4}/'),
   ('PL', 'NN-NNN'),
   ('PN', '/PCRN 1ZZ/'),
   ('PR', '/00[6-9]\d{2}(-([1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/'),
   ('PS', 'NNN'),
   ('PT', '/[1-9]\d{3}(-\d{3})?/'),
   ('PW', '/96940(-([1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/'),
   ('PY', 'NNNN[NN]'),
   ('RO', 'NNNNNN'),
   ('RS', 'NNNNN'),
   ('RU', 'NNNNNN'),
   ('SA', 'NNNNN[-NNNN]'),
   ('SD', 'NNNNN'),
   ('SE', '/[1-9]\d{2} \d{2}/'),
   ('SG', 'NNNNNN'),
   ('SH', '/(STHL|ASCN|TDCU) 1ZZ/'),
   ('SI', '/[1-9]\d{3}/'),
   ('SJ', 'NNNN'),
   ('SK', 'NNN NN'),
   ('SM', '/4789\d/'),
   ('SN', 'NNNNN'),
   ('SO', 'AA NNNNN'),
   ('SV', 'NNNN[N]'),
   ('SZ', '/[HLMS]\d{3}/'),
   ('TC', '/TKCA 1ZZ/'),
   ('TH', 'NNNNN'),
   ('TJ', 'NNNNNN'),
   ('TM', 'NNNNNN'),
   ('TN', '/[1-9]\d{3}/'),
   ('TR', '/(0[1-9]|[1-7]\d|8[01]|99)\d{3}/'),
   ('TT', 'NNNNNN'),
   ('TW', '/\d{3}(-\d{2,3})?/'),
   ('TZ', 'NNNNN'),
   ('UA', '/(0[1-9]|[1-9]\d)\d{3}/'),
   ('UM', '/96898(-([1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/'),
   ('UY', '/[1-9]\d{4}/'),
   ('UZ', 'NNNNNN'),
   ('VA', '/00120/'),
   ('VC', 'NNNN'),
   ('VE', 'NNNN[-A]'),
   ('VG', 'NNNN'),
   ('VI', '/008\d{2}(-([1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/'),
   ('VN', 'NNNNN[N]'),
   ('WS', 'NNNN'),
   ('XK', 'NNNNN'),
   ('ZA', 'NNNN'),
   ('ZM', 'NNNNN')
) v(iso2, spec);
INSERT INTO postal_code_builtin_countries (iso2, format_name) VALUES
   ('AD', 'pattern'),
   ('AE', 'pattern'),
   ('AF', 'pattern'),
   ('AI', 'pattern'),
   ('AL', 'pattern'),
   ('AM', 'pattern'),
   ('AQ', 'pattern'),
   ('AR', 'pattern'),
   ('AS', 'pattern'),
   ('AT', 'pattern'),
   ('AU', 'pattern'),
   ('AX', 'pattern'),
   ('AZ', 'pattern'),
   ('BA', 'pattern'),
   ('BB', 'pattern'),
   ('BD', 'pattern'),
   ('BE', 'pattern'),
   ('BG', 'pattern'),
   ('BH', 'pattern'),
   ('BL', 'FR'),
   ('BM', 'pattern'),
   ('BN', 'pattern'),
   ('BT', 'pattern'),
   ('BY', 'pattern'),
   ('CC', 'pattern'),
   ('CH', 'pattern'),
   ('CL', 'pattern'),
   ('CN', 'pattern'),
   ('CO', 'pattern'),
   ('CR', 'pattern'),
   ('CU', 'pattern'),
   ('CV', 'pattern'),
   ('CX', 'pattern'),
   ('CY', 'pattern'),
   ('DE', 'pattern'),
   ('DK', 'pattern'),
   ('DO', 'pattern'),
   ('DZ', 'pattern'),
   ('EC', 'pattern'),
   ('EE', 'pattern'),
   ('EG', 'pattern'),
   ('ES', 'pattern'),
   ('ET', 'pattern'),
   ('FI', 'pattern'),
   ('FK', 'pattern'),
   ('FM', 'pattern'),
   ('FO', 'pattern'),
   ('GE', 'pattern'),
   ('GF', 'FR'),
   ('GH', 'pattern'),
   ('GI', 'GB'),
   ('GL', 'pattern'),
   ('GN', 'pattern'),
   ('GP', 'FR'),
   ('GR', 'pattern'),
   ('GS', 'pattern'),
   ('GT', 'pattern'),
   ('GU', 'pattern'),
   ('GW', 'pattern'),
   ('HK', 'pattern'),
   ('HM', 'pattern'),
   ('HN', 'pattern'),
   ('HR', 'pattern'),
   ('HT', 'pattern'),
   ('HU', 'pattern'),
   ('ID', 'pattern'),
   ('IL', 'pattern'),
   ('IN', 'pattern'),
   ('IO', 'pattern'),
   ('IQ', 'pattern'),
   ('IR', 'pattern'),
   ('IS', 'pattern'),
   ('IT', 'pattern'),
   ('JM', 'pattern'),
   ('JO', 'pattern'),
   ('JP', 'pattern'),
   ('KE', 'pattern'),
   ('KG', 'pattern'),
   ('KH', 'pattern'),
   ('KN', 'pattern'),
   ('KR', 'pattern'),
   ('KW', 'pattern'),
   ('KY', 'pattern'),
   ('KZ', 'pattern'),
   ('LA', 'pattern'),
   ('LB', 'pattern'),
   ('LC', 'pattern'),
   ('LI', 'pattern'),
   ('LK', 'pattern'),
   ('LR', 'pattern'),
   ('LS', 'pattern'),
   ('LT', 'pattern'),
   ('LV', 'pattern'),
   ('MA', 'pattern'),
   ('MC', 'pattern'),
   ('MD', 'pattern'),
   ('ME', 'pattern'),
   ('MF', 'FR'),
   ('MG', 'pattern'),
   ('MH', 'pattern'),
   ('MK', 'pattern'),
   ('MM', 'pattern'),
   ('MN', 'pattern'),
   ('MO', 'pattern'),
   ('MP', 'pattern'),
   ('MQ', 'FR'),
   ('MS', 'pattern'),
   ('MT', 'pattern'),
   ('MU', 'pattern'),
   ('MV', 'pattern'),
   ('MW', 'pattern'),
   ('MX', 'pattern'),
   ('MY', 'pattern'),
   ('MZ', 'pattern'),
   ('NA', 'pattern'),
   ('NC', 'FR'),
   ('NE', 'pattern'),
   ('NF', 'pattern'),
   ('NG', 'pattern'),
   ('NI', 'pattern'),
   ('NL', 'pattern'),
   ('NO', 'pattern'),
   ('NP', 'pattern'),
   ('NR', 'pattern'),
   ('NU', 'pattern'),
   ('NZ', 'pattern'),
   ('OM', 'pattern'),
   ('PA', 'pattern'),
   ('PE', 'pattern'),
   ('PF', 'FR'),
   ('PG', 'pattern'),
   ('PH', 'pattern'),
   ('PK', 'pattern'),
   ('PL', 'pattern'),
   ('PM', 'FR'),
   ('PN', 'pattern'),
   ('PR', 'pattern'),
   ('PS', 'pattern'),
   ('PT', 'pattern'),
   ('PW', 'pattern'),
   ('PY', 'pattern'),
   ('RE', 'FR'),
   ('RO', 'pattern'),
   ('RS', 'pattern'),
   ('RU', 'pattern'),
   ('SA', 'pattern'),
   ('SD', 'pattern'),
   ('SE', 'pattern'),
   ('SG', 'pattern'),
   ('SH', 'pattern'),
   ('SI', 'pattern'),
   ('SJ', 'pattern'),
   ('SK', 'pattern'),
   ('SM', 'pattern'),
   ('SN', 'pattern'),
   ('SO', 'pattern'),
   ('SV', 'pattern'),
   ('SZ', 'pattern'),
   ('TC', 'pattern'),
   ('TH', 'pattern'),
   ('TJ', 'pattern'),
   ('TM', 'pattern'),
   ('TN', 'pattern'),
   ('TR', 'pattern'),
   ('TT', 'pattern'),
   ('TW', 'pattern'),
   ('TZ', 'pattern'),
   ('UA', 'pattern'),
   ('UM', 'pattern'),
   ('UY', 'pattern'),
   ('UZ', 'pattern'),
   ('VA', 'pattern'),
   ('VC', 'pattern'),
   ('VE', 'pattern'),
   ('VG', 'pattern'),
   ('VI', 'pattern'),
   ('VN', 'pattern'),
   ('WF', 'FR'),
   ('WS', 'pattern'),
   ('XK', 'pattern'),
   ('YT', 'FR'),
   ('ZA', 'pattern'),
   ('ZM', 'pattern');
INSERT INTO postal_code_iso_countries (iso2, name, basis, note) VALUES
   ('AD', 'Andorra
', 'GeoNames data', '100 to 799 (written AD500)'),
   ('AE', 'United Arab Emirates
', 'see note', 'no postal code system, but two location schemes: Abu Dhabi has 5-digit area codes (20000 central Abu Dhabi, 23251 Khalifa City, 20014 Yas Island), and Dubai numbers every building with a 10-digit Makani code written NNNNN NNNNN (all 178,171 GeoNames rows are Dubai). One format holds both, so any 5 digits pass. Sharjah''s PCS is not modelled; most UAE addresses give a PO Box, which is rejected'),
   ('AF', 'Afghanistan
', 'Wikipedia', NULL),
   ('AG', 'Antigua and Barbuda
', 'no postal codes', NULL),
   ('AI', 'Anguilla
', 'GeoNames data', 'a single code, 2640 (written AI-2640)'),
   ('AL', 'Albania
', 'GeoNames data', NULL),
   ('AM', 'Armenia
', 'Wikipedia', NULL),
   ('AO', 'Angola
', 'no postal codes', NULL),
   ('AQ', 'British Antarctic Territory
', 'Wikipedia', 'a single code, BIQQ 1ZZ'),
   ('AR', 'Argentina
', 'see note', 'NNNN (the legacy code, and what GeoNames has), the province letter + 4 digits (B1832), or the full 8-character CPA (B1832GMR); all three are common in OpenStreetMap'),
   ('AS', 'American Samoa
', 'GeoNames data', 'US ZIP 96799'),
   ('AT', 'Austria
', 'GeoNames data', NULL),
   ('AU', 'Australia
', 'GeoNames data', NULL),
   ('AW', 'Aruba
', 'no postal codes', NULL),
   ('AX', 'Åland
', 'GeoNames data', '22xxx'),
   ('AZ', 'Azerbaijan
', 'GeoNames data', NULL),
   ('BA', 'Bosnia and Herzegovina
', 'Wikipedia', NULL),
   ('BB', 'Barbados
', 'Wikipedia', NULL),
   ('BD', 'Bangladesh
', 'GeoNames data', NULL),
   ('BE', 'Belgium
', 'GeoNames data', NULL),
   ('BF', 'Burkina Faso
', 'no postal codes', NULL),
   ('BG', 'Bulgaria
', 'GeoNames data', NULL),
   ('BH', 'Bahrain
', 'Wikipedia', NULL),
   ('BI', 'Burundi
', 'no postal codes', NULL),
   ('BJ', 'Benin
', 'no postal codes', NULL),
   ('BL', 'Saint Barthélemy
', 'Wikipedia', 'the French format'),
   ('BM', 'Bermuda
', 'see note', 'AA NN; the second pair is sometimes letters, so X; Wikipedia lists AA NN and AA AA'),
   ('BN', 'Brunei
', 'Wikipedia', NULL),
   ('BO', 'Bolivia
', 'no postal codes', NULL),
   ('BQ', 'Bonaire, Sint Eustatius and Saba
', 'no postal codes', NULL),
   ('BR', 'Brazil
', 'built in', NULL),
   ('BS', 'Bahamas
', 'no postal codes', NULL),
   ('BT', 'Bhutan
', 'Wikipedia', NULL),
   ('BV', 'Bouvet Island', 'no postal codes', NULL),
   ('BW', 'Botswana
', 'no postal codes', NULL),
   ('BY', 'Belarus
', 'GeoNames data', NULL),
   ('BZ', 'Belize
', 'no postal codes', NULL),
   ('CA', 'Canada
', 'built in', NULL),
   ('CC', 'Cocos (Keeling) Island
', 'GeoNames data', NULL),
   ('CD', 'Congo, Democratic Republic
', 'no postal codes', NULL),
   ('CF', 'Central African Republic
', 'no postal codes', NULL),
   ('CG', 'Congo (Brazzaville)
', 'no postal codes', NULL),
   ('CH', 'Switzerland
', 'GeoNames data', NULL),
   ('CI', 'Côte d''Ivoire (Ivory Coast)
', 'no postal codes', NULL),
   ('CK', 'Cook Islands
', 'no postal codes', NULL),
   ('CL', 'Chile
', 'GeoNames data', NULL),
   ('CM', 'Cameroon
', 'no postal codes', NULL),
   ('CN', 'China
', 'GeoNames data', NULL),
   ('CO', 'Colombia
', 'GeoNames data', 'six digits, with the optional -NNN extension seen in a quarter of OpenStreetMap values (630001-025)'),
   ('CR', 'Costa Rica
', 'GeoNames data', 'five digits; Wikipedia also lists a NNNNN-NNNN street-level extension, taken as the optional tail'),
   ('CU', 'Cuba
', 'Wikipedia', NULL),
   ('CV', 'Cape Verde
', 'Wikipedia', NULL),
   ('CW', 'Curaçao
', 'no postal codes', NULL),
   ('CX', 'Christmas Island
', 'GeoNames data', NULL),
   ('CY', 'Cyprus
', 'GeoNames data', NULL),
   ('CZ', 'Czech Republic
', 'built in', NULL),
   ('DE', 'Germany
', 'GeoNames data', 'five digits, never starting 00; Wikipedia also lists the 2- and 4-digit regional leading digits (Leitregion), which are prefixes, not codes: search them with the % operator'),
   ('DJ', 'Djibouti
', 'no postal codes', NULL),
   ('DK', 'Denmark
', 'GeoNames data', NULL),
   ('DM', 'Dominica
', 'no postal codes', NULL),
   ('DO', 'Dominican Republic
', 'GeoNames data', NULL),
   ('DZ', 'Algeria
', 'GeoNames data', NULL),
   ('EC', 'Ecuador
', 'GeoNames data', NULL),
   ('EE', 'Estonia
', 'GeoNames data', NULL),
   ('EG', 'Egypt
', 'see note', 'Wikipedia says 7 digits, the post office uses 5; both accepted'),
   ('EH', 'Western Sahara', 'no postal codes', NULL),
   ('ER', 'Eritrea
', 'no postal codes', NULL),
   ('ES', 'Spain
', 'GeoNames data', 'province 01 to 52'),
   ('ET', 'Ethiopia
', 'Wikipedia', NULL),
   ('FI', 'Finland
', 'GeoNames data', NULL),
   ('FJ', 'Fiji
', 'no postal codes', NULL),
   ('FK', 'Falkland Islands
', 'GeoNames data', 'a single code, FIQQ 1ZZ'),
   ('FM', 'Micronesia
', 'GeoNames data', 'US ZIPs 96941 to 96944'),
   ('FO', 'Faroe Islands
', 'GeoNames data', NULL),
   ('FR', 'France
', 'built in', NULL),
   ('GA', 'Gabon
', 'no postal codes', NULL),
   ('GB', 'United Kingdom
', 'built in', NULL),
   ('GD', 'Grenada
', 'no postal codes', NULL),
   ('GE', 'Georgia
', 'Wikipedia', NULL),
   ('GF', 'French Guiana
', 'GeoNames data', 'the French format: the overseas departments use CEDEX too, which a 97xxx/98xxx pattern would refuse (GeoNames has "97305 CEDEX")'),
   ('GG', 'Guernsey
', 'built in', NULL),
   ('GH', 'Ghana
', 'Wikipedia', 'a letter, a letter or digit, then 3 to 5 digits (Wikipedia: A?NNN, A?NNNN, A?NNNNN)'),
   ('GI', 'Gibraltar
', 'see note', 'GX11 1AA, the UK format'),
   ('GL', 'Greenland
', 'GeoNames data', NULL),
   ('GM', 'Gambia
', 'no postal codes', NULL),
   ('GN', 'Guinea
', 'Wikipedia', NULL),
   ('GP', 'Guadeloupe
', 'GeoNames data', 'the French format (CEDEX)'),
   ('GQ', 'Equatorial Guinea
', 'no postal codes', NULL),
   ('GR', 'Greece
', 'Wikipedia', NULL),
   ('GS', 'South Georgia and the South Sandwich Islands
', 'GeoNames data', 'a single code, SIQQ 1ZZ'),
   ('GT', 'Guatemala
', 'GeoNames data', NULL),
   ('GU', 'Guam
', 'GeoNames data', 'US ZIPs 969xx'),
   ('GW', 'Guinea Bissau
', 'Wikipedia', NULL),
   ('GY', 'Guyana
', 'no postal codes', NULL),
   ('HK', 'Hong Kong
', 'see note', 'no postal codes; 999077 is the placeholder GeoNames carries'),
   ('HM', 'Heard and McDonald Islands
', 'GeoNames data', NULL),
   ('HN', 'Honduras
', 'GeoNames data', 'five digits (GeoNames); Wikipedia also lists an older AANNNN form, not accepted'),
   ('HR', 'Croatia
', 'GeoNames data', NULL),
   ('HT', 'Haiti
', 'GeoNames data', NULL),
   ('HU', 'Hungary
', 'GeoNames data', NULL),
   ('ID', 'Indonesia
', 'GeoNames data', NULL),
   ('IE', 'Ireland
', 'built in', NULL),
   ('IL', 'Israel
', 'see note', '7 digits since 2013; 5-digit codes are still widely used; both accepted'),
   ('IM', 'Isle of Man
', 'built in', NULL),
   ('IN', 'India
', 'GeoNames data', NULL),
   ('IO', 'British Indian Ocean Territory
', 'GeoNames data', 'a single code, BBND 1ZZ'),
   ('IQ', 'Iraq
', 'Wikipedia', NULL),
   ('IR', 'Iran
', 'Wikipedia', 'the 10-digit code, whose first five digits are a locality block; OpenStreetMap''s mapped postcode areas use those five alone, so the second half is optional'),
   ('IS', 'Iceland
', 'GeoNames data', NULL),
   ('IT', 'Italy
', 'GeoNames data', NULL),
   ('JE', 'Jersey
', 'built in', NULL),
   ('JM', 'Jamaica
', 'Wikipedia', NULL),
   ('JO', 'Jordan
', 'Wikipedia', NULL),
   ('JP', 'Japan
', 'GeoNames data', NULL),
   ('KE', 'Kenya
', 'GeoNames data', NULL),
   ('KG', 'Kyrgyzstan
', 'Wikipedia', NULL),
   ('KH', 'Cambodia
', 'Wikipedia', NULL),
   ('KI', 'Kiribati
', 'no postal codes', NULL),
   ('KM', 'Comoros
', 'no postal codes', NULL),
   ('KN', 'Saint Kitts and Nevis
', 'Wikipedia', NULL),
   ('KP', 'Korea, North
', 'no postal codes', NULL),
   ('KR', 'Korea, South
', 'GeoNames data', 'area 01 to 63'),
   ('KW', 'Kuwait
', 'Wikipedia', NULL),
   ('KY', 'Cayman Islands
', 'Wikipedia', NULL),
   ('KZ', 'Kazakhstan
', 'Wikipedia', 'six digits, or the newer alphanumeric form A05B1H4'),
   ('LA', 'Laos
', 'Wikipedia', NULL),
   ('LB', 'Lebanon
', 'Wikipedia', NULL),
   ('LC', 'Saint Lucia
', 'Wikipedia', NULL),
   ('LI', 'Liechtenstein
', 'GeoNames data', '9485 to 9498'),
   ('LK', 'Sri Lanka
', 'GeoNames data', NULL),
   ('LR', 'Liberia
', 'Wikipedia', NULL),
   ('LS', 'Lesotho
', 'Wikipedia', NULL),
   ('LT', 'Lithuania
', 'GeoNames data', NULL),
   ('LU', 'Luxembourg
', 'built in', NULL),
   ('LV', 'Latvia
', 'GeoNames data', NULL),
   ('LY', 'Libya
', 'no postal codes', NULL),
   ('MA', 'Morocco
', 'GeoNames data', NULL),
   ('MC', 'Monaco
', 'GeoNames data', '980xx'),
   ('MD', 'Moldova
', 'GeoNames data', NULL),
   ('ME', 'Montenegro
', 'Wikipedia', NULL),
   ('MF', 'Saint Martin
', 'Wikipedia', 'the French format'),
   ('MG', 'Madagascar
', 'Wikipedia', NULL),
   ('MH', 'Marshall Islands
', 'GeoNames data', 'US ZIPs 96960 to 96979 (969 6x/7x)'),
   ('MK', 'North Macedonia
', 'GeoNames data', NULL),
   ('ML', 'Mali
', 'no postal codes', NULL),
   ('MM', 'Myanmar
', 'see note', 'Wikipedia says 7 digits, 5 are in use; both accepted'),
   ('MN', 'Mongolia
', 'Wikipedia', NULL),
   ('MO', 'Macau
', 'see note', 'no postal codes; 999078 is the placeholder GeoNames carries'),
   ('MP', 'Northern Mariana Islands
', 'GeoNames data', 'US ZIPs 96950 to 96952'),
   ('MQ', 'Martinique
', 'GeoNames data', 'the French format (CEDEX)'),
   ('MR', 'Mauritania
', 'no postal codes', NULL),
   ('MS', 'Montserrat
', 'Wikipedia', 'MSR followed by four digits'),
   ('MT', 'Malta
', 'see note', 'the outcode alone (GeoNames has these), optionally with NNNN'),
   ('MU', 'Mauritius
', 'Wikipedia', NULL),
   ('MV', 'Maldives
', 'Wikipedia', NULL),
   ('MW', 'Malawi
', 'GeoNames data', NULL),
   ('MX', 'Mexico
', 'GeoNames data', NULL),
   ('MY', 'Malaysia
', 'GeoNames data', NULL),
   ('MZ', 'Mozambique
', 'Wikipedia', 'four digits, with the optional -NN extension seen in OpenStreetMap values (0101-01)'),
   ('NA', 'Namibia
', 'Wikipedia', NULL),
   ('NC', 'New Caledonia
', 'GeoNames data', 'the French format'),
   ('NE', 'Niger
', 'Wikipedia', NULL),
   ('NF', 'Norfolk Island
', 'GeoNames data', NULL),
   ('NG', 'Nigeria
', 'Wikipedia', NULL),
   ('NI', 'Nicaragua
', 'Wikipedia', NULL),
   ('NL', 'Netherlands
', 'see note', 'four digits (the first never 0), optionally with two letters (never F I O Q U Y, never SA SD SS)'),
   ('NO', 'Norway
', 'GeoNames data', NULL),
   ('NP', 'Nepal
', 'Wikipedia', NULL),
   ('NR', 'Nauru
', 'GeoNames data', NULL),
   ('NU', 'Niue
', 'GeoNames data', NULL),
   ('NZ', 'New Zealand
', 'GeoNames data', NULL),
   ('OM', 'Oman
', 'Wikipedia', NULL),
   ('PA', 'Panama
', 'see note', 'Wikipedia says 4 digits, GeoNames has 5; both accepted'),
   ('PE', 'Peru
', 'GeoNames data', 'five digits; Wikipedia also lists a CC NNNN form, not accepted'),
   ('PF', 'French Polynesia
', 'GeoNames data', 'the French format'),
   ('PG', 'Papua New Guinea
', 'Wikipedia', NULL),
   ('PH', 'Philippines
', 'GeoNames data', NULL),
   ('PK', 'Pakistan
', 'GeoNames data', NULL),
   ('PL', 'Poland
', 'GeoNames data', NULL),
   ('PM', 'Saint Pierre and Miquelon
', 'GeoNames data', 'the French format'),
   ('PN', 'Pitcairn Islands
', 'GeoNames data', 'a single code, PCRN 1ZZ'),
   ('PR', 'Puerto Rico
', 'GeoNames data', 'US ZIPs 006xx to 009xx'),
   ('PS', 'Palestine
', 'Wikipedia', NULL),
   ('PT', 'Portugal
', 'GeoNames data', NULL),
   ('PW', 'Palau
', 'GeoNames data', 'US ZIP 96940'),
   ('PY', 'Paraguay
', 'Wikipedia', NULL),
   ('QA', 'Qatar
', 'no postal codes', NULL),
   ('RE', 'Réunion
', 'GeoNames data', 'the French format (CEDEX)'),
   ('RO', 'Romania
', 'GeoNames data', NULL),
   ('RS', 'Serbia
', 'GeoNames data', NULL),
   ('RU', 'Russia
', 'GeoNames data', NULL),
   ('RW', 'Rwanda
', 'no postal codes', NULL),
   ('SA', 'Saudi Arabia
', 'Wikipedia', NULL),
   ('SB', 'Solomon Islands
', 'no postal codes', NULL),
   ('SC', 'Seychelles
', 'no postal codes', NULL),
   ('SD', 'Sudan
', 'Wikipedia', NULL),
   ('SE', 'Sweden
', 'GeoNames data', NULL),
   ('SG', 'Singapore
', 'GeoNames data', 'six digits; Wikipedia also lists the old 2- and 4-digit forms, not accepted; Singapore also uses non-sequential sectors (88, 91), so it is not tightened'),
   ('SH', 'Saint Helena, Ascension and Tristan da Cunha
', 'Wikipedia', 'three codes: STHL, ASCN and TDCU, each 1ZZ'),
   ('SI', 'Slovenia
', 'GeoNames data', NULL),
   ('SJ', 'Svalbard and Jan Mayen
', 'GeoNames data', NULL),
   ('SK', 'Slovakia
', 'GeoNames data', NULL),
   ('SL', 'Sierra Leone
', 'no postal codes', NULL),
   ('SM', 'San Marino
', 'GeoNames data', '4789x'),
   ('SN', 'Senegal
', 'Wikipedia', NULL),
   ('SO', 'Somalia
', 'Wikipedia', NULL),
   ('SR', 'Suriname
', 'no postal codes', NULL),
   ('SS', 'South Sudan
', 'no postal codes', NULL),
   ('ST', 'São Tomé and Príncipe
', 'no postal codes', NULL),
   ('SV', 'El Salvador
', 'Wikipedia', NULL),
   ('SX', 'Sint Maarten
', 'no postal codes', NULL),
   ('SY', 'Syria
', 'no postal codes', NULL),
   ('SZ', 'Eswatini
', 'Wikipedia', NULL),
   ('TC', 'Turks and Caicos Islands
', 'GeoNames data', 'a single code, TKCA 1ZZ'),
   ('TD', 'Chad
', 'no postal codes', NULL),
   ('TF', 'French Southern and Antarctic Territories
', 'no postal codes', NULL),
   ('TG', 'Togo
', 'no postal codes', NULL),
   ('TH', 'Thailand
', 'GeoNames data', NULL),
   ('TJ', 'Tajikistan
', 'Wikipedia', NULL),
   ('TK', 'Tokelau
', 'no postal codes', NULL),
   ('TL', 'East Timor
', 'no postal codes', NULL),
   ('TM', 'Turkmenistan
', 'Wikipedia', NULL),
   ('TN', 'Tunisia
', 'Wikipedia', NULL),
   ('TO', 'Tonga
', 'no postal codes', NULL),
   ('TR', 'Turkey
', 'GeoNames data', 'province 01 to 81, and 99 (the Turkish-controlled north of Cyprus)'),
   ('TT', 'Trinidad and Tobago
', 'Wikipedia', NULL),
   ('TV', 'Tuvalu
', 'no postal codes', NULL),
   ('TW', 'Taiwan
', 'Wikipedia', 'three digits with an optional 2 or 3 digit extension (100, 100-12, 100-123)'),
   ('TZ', 'Tanzania
', 'Wikipedia', NULL),
   ('UA', 'Ukraine
', 'GeoNames data', NULL),
   ('UG', 'Uganda
', 'no postal codes', NULL),
   ('UM', 'United States Minor Outlying Islands
', 'Wikipedia', 'US ZIP (96898)'),
   ('US', 'United States
', 'built in', NULL),
   ('UY', 'Uruguay
', 'GeoNames data', NULL),
   ('UZ', 'Uzbekistan
', 'Wikipedia', NULL),
   ('VA', 'Vatican
', 'GeoNames data', 'a single code, 00120'),
   ('VC', 'Saint Vincent and the Grenadines
', 'Wikipedia', NULL),
   ('VE', 'Venezuela
', 'Wikipedia', NULL),
   ('VG', 'British Virgin Islands
', 'Wikipedia', NULL),
   ('VI', 'U.S. Virgin Islands
', 'GeoNames data', 'US ZIPs 008xx'),
   ('VN', 'Vietnam
', 'see note', 'Wikipedia says 5 digits; 6 are in use since 2004; both accepted'),
   ('VU', 'Vanuatu
', 'no postal codes', NULL),
   ('WF', 'Wallis and Futuna
', 'GeoNames data', 'the French format'),
   ('WS', 'Samoa
', 'see note', 'Wikipedia: four digits; the one GeoNames row is American Samoa''s ZIP, filed under the wrong country'),
   ('XK', 'Kosovo
', 'Wikipedia', NULL),
   ('YE', 'Yemen
', 'no postal codes', NULL),
   ('YT', 'Mayotte
', 'GeoNames data', 'the French format (CEDEX)'),
   ('ZA', 'South Africa
', 'GeoNames data', NULL),
   ('ZM', 'Zambia
', 'Wikipedia', NULL),
   ('ZW', 'Zimbabwe
', 'no postal codes', NULL);
-- END generated

CREATE VIEW postal_code_world AS
   SELECT i.iso2, i.name,
          CASE WHEN f.format_name = 'pattern' THEN l.source ELSE f.format_name END AS format,
          COALESCE(f.builtin, false) AS builtin, i.basis, i.note
   FROM postal_code_iso_countries i
   LEFT JOIN postal_code_country_formats f ON f.iso2 = i.iso2
   LEFT JOIN postal_code_languages l ON f.format_name = 'pattern' AND l.iso2 = i.iso2
        AND l.version = (SELECT max(l2.version) FROM postal_code_languages l2 WHERE l2.iso2 = i.iso2)
   ORDER BY i.iso2;
COMMENT ON VIEW postal_code_world IS
   'Every country and territory with the postal code format it is assigned (NULL if none) and where that came from. SELECT * FROM postal_code_world WHERE format IS NULL AND basis <> ''no postal codes'' lists any country still to be added.';


-- A range of postal codes: a native PostgreSQL range type, so it comes with
-- <@ / @> / && / -|- (adjacent) and multiranges for free. [lo, hi) is built
-- from a fragment by postal_prefix('GB-LS24').
--
--   WHERE pc <@ postal_prefix('GB-LS24')
--
-- The bounds are postal_code VALUES but are bounds, not addresses: a bound
-- that is the successor of a prefix need not be a code anyone has, and at the
-- top of a country it is the end-of-country bound 'US-~'. Using a bound as a
-- postcode is bad practice. A prefix range is never open-ended: PostgreSQL's
-- "no upper end" means the end of the WHOLE value space, and countries lie end
-- to end in it, so [BR-99000,) would run on through every later country.
CREATE TYPE postal_code_range AS RANGE (subtype = postal_code);

-- Named postal_prefix, NOT postal_code_range: PostgreSQL reads
-- typename('literal') as a cast to that type, so a one-argument function
-- sharing its return type's name is never reached with a string literal.
--
-- STABLE, like postal_code_in, because the answer depends on which format a
-- country is assigned. The support function folds a call with a CONSTANT
-- fragment into a constant range at plan time, so that PostgreSQL's own
-- rewrite of `col <@ <constant range>` into btree conditions applies and a
-- prefix search uses the index. To keep that safe the folded plan is made to
-- depend on postal_code_user_countries, and the trigger below invalidates
-- such plans whenever that table changes.
CREATE FUNCTION postal_prefix_support(internal)
   RETURNS internal
   AS 'MODULE_PATHNAME', 'postal_code_prefix_support'
   LANGUAGE C;

CREATE FUNCTION postal_prefix(text)
   RETURNS postal_code_range
   AS 'MODULE_PATHNAME', 'postal_code_prefix'
   LANGUAGE C STABLE STRICT
   SUPPORT postal_prefix_support;

CREATE FUNCTION to_postal_prefix(text)
   RETURNS postal_code_range
   AS 'MODULE_PATHNAME', 'postal_code_prefix_lenient'
   LANGUAGE C STABLE STRICT;
COMMENT ON FUNCTION to_postal_prefix(text) IS
   'postal_prefix() that returns NULL instead of raising when the text is not a fragment of an assigned country''s postal codes (no CC- prefix, unassigned country, not a prefix of that format).';

CREATE FUNCTION postal_code_formats_changed()
   RETURNS trigger
   AS 'MODULE_PATHNAME'
   LANGUAGE C;

CREATE TRIGGER postal_code_user_countries_changed
   AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON postal_code_user_countries
   FOR EACH STATEMENT EXECUTE FUNCTION postal_code_formats_changed();
-- ... and likewise the language cache: a language added in a transaction that then rolls back must
-- not linger in other backends' caches, and a new version changes what a country's text means.
CREATE TRIGGER postal_code_languages_changed
   AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON postal_code_languages
   FOR EACH STATEMENT EXECUTE FUNCTION postal_code_formats_changed();


-- The partial-match operator, ported from the UK type:
--
--   WHERE pc % 'GB-LS24'        -- pc starts with the fragment
--   WHERE pc !% 'GB-LS24'       -- ... or doesn't
--
-- Same meaning as `pc <@ postal_prefix('GB-LS24')`, with the UK operator's
-- leniency: a fragment that isn't one (no "CC-", an unassigned country, not
-- a prefix of that format) matches nothing, and !% matches everything -- it is
-- meant to be fed arbitrary input such as a search box, where an error would
-- be the wrong answer. postal_prefix()/lower_bound()/upper_bound() still raise,
-- since they are for building a query from a known-good fragment.
--
-- With a constant fragment the support function rewrites it at plan time into
-- `pc >= lo AND pc < hi`, so it uses a btree index through the ordinary sound
-- strategies; % itself is deliberately NOT registered in the btree operator
-- family (it is not an equivalence relation -- two different codes can both
-- match the same fragment -- and registering it was a real bug in the UK
-- type's 1.3.0). The rewritten plan depends on postal_code_user_countries and
-- is invalidated when it changes, like postal_prefix().
CREATE FUNCTION postal_code_partial_support(internal)
   RETURNS internal
   AS 'MODULE_PATHNAME', 'postal_code_partial_support'
   LANGUAGE C;

CREATE FUNCTION postal_code_partial(postal_code, text)
   RETURNS boolean
   AS 'MODULE_PATHNAME', 'postal_code_partial'
   LANGUAGE C STABLE STRICT
   SUPPORT postal_code_partial_support;

CREATE FUNCTION postal_code_not_partial(postal_code, text)
   RETURNS boolean
   AS 'MODULE_PATHNAME', 'postal_code_not_partial'
   LANGUAGE C STABLE STRICT;

CREATE OPERATOR % (
   PROCEDURE = postal_code_partial,
   LEFTARG   = postal_code,
   RIGHTARG  = text,
   NEGATOR   = !%,
   RESTRICT  = matchingsel,
   JOIN      = matchingjoinsel
);

CREATE OPERATOR !% (
   PROCEDURE = postal_code_not_partial,
   LEFTARG   = postal_code,
   RIGHTARG  = text,
   NEGATOR   = %,
   RESTRICT  = matchingsel,
   JOIN      = matchingjoinsel
);


-- Which columns are locked to which country, the postal_code analogue of
-- PostGIS's geometry_columns.
CREATE VIEW postal_code_columns AS
SELECT n.nspname AS schema_name,
       c.relname AS table_name,
       a.attname AS column_name,
       CASE WHEN a.atttypmod >= 0
            THEN chr(65 + a.atttypmod / 32) || chr(65 + a.atttypmod % 32)
       END AS locked_to_country
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE a.atttypid = 'postal_code'::regtype
  AND a.attnum > 0
  AND NOT a.attisdropped
  AND c.relkind IN ('r', 'p', 'v', 'm', 'f');
COMMENT ON VIEW postal_code_columns IS
  'Every column of type postal_code, and the country it is locked to (NULL = not locked). A column declared postal_code(''US'') is locked to US.';


-- additions in 2.1.0 -- see postcode--2.0.1--2.1.0.sql for the standalone upgrade version of this section.

-- postcode 2.0.1 -> 2.1.0: named parts.
--
-- A pattern may now name parts of a code with (?<name>...) -- see NAMED_PARTS.md:
--
--   SELECT add_country_template('XQ', '/(?<major>\d{2})-(?<minor>\d{3})/');
--   SELECT part('XQ-12-345', 'major');                -- '12'
--   SELECT parts('XQ-12-345');                         -- {"major": "12", "minor": "345"}  (jsonb orders its keys itself)
--   SELECT prefix_of('XQ-12-345', 'major');            -- the range of every code that starts 'XQ-12'
--
-- A name changes nothing about which codes are valid or how they are stored or ranked, so nothing already
-- stored is touched. The compiled formats (GB, US, CA, IE, BR) get named parts from the table
-- postal_code_format_parts, and the UK postcode type has the same four parts as GB. Nothing in 2.0.x is removed; to_char(postcode, text) is marked deprecated.

CREATE FUNCTION postal_code_pattern_part_names(text)
   RETURNS text[]
   AS 'MODULE_PATHNAME', 'postal_code_pattern_part_names'
   LANGUAGE C IMMUTABLE STRICT;
COMMENT ON FUNCTION postal_code_pattern_part_names(text) IS
   'The names a postal_code regular expression gives its parts with (?<name>...), in the order they appear.';

CREATE FUNCTION postal_code_same_codes(text, text)
   RETURNS boolean
   AS 'MODULE_PATHNAME', 'postal_code_same_codes'
   LANGUAGE C IMMUTABLE STRICT;
COMMENT ON FUNCTION postal_code_same_codes(text, text) IS
   'Whether two postal_code regular expressions denote exactly the same set of codes, however differently they are written or named. Exact (it compares the compiled automata). A stored code''s meaning depends only on that set, so such patterns rank every code the same.';

CREATE FUNCTION postal_code_parts_check(text)
   RETURNS text
   AS 'MODULE_PATHNAME', 'postal_code_parts_check'
   LANGUAGE C STABLE STRICT;
COMMENT ON FUNCTION postal_code_parts_check(text) IS
   'Checks that the named parts of a postal_code regular expression split every code one way only. Raises an error with an example code if some code splits two ways. Returns a message if only some of the codes could be checked, otherwise NULL.';

CREATE FUNCTION part(postal_code, text)
   RETURNS text
   AS 'MODULE_PATHNAME', 'postal_code_part'
   LANGUAGE C STABLE STRICT;
COMMENT ON FUNCTION part(postal_code, text) IS
   'The named part of a postal code, as the piece of text it is: part(''GB-SW1A 1AA'', ''district'') is ''1A''. NULL if this code has no such part (an optional part that is absent). An error, listing the parts there are, if the country has no part of that name or no named parts at all.';

CREATE FUNCTION parts(postal_code)
   RETURNS jsonb
   AS 'MODULE_PATHNAME', 'postal_code_parts_json'
   LANGUAGE C STABLE STRICT;
COMMENT ON FUNCTION parts(postal_code) IS
   'All the named parts of a postal code as jsonb; a part the code does not have is null. (jsonb keeps its keys in its own order; the order in the pattern is the ord column of postal_code_parts.) See postal_code_parts for the parts each country has.';

CREATE FUNCTION postal_code_part_end(postal_code, text)
   RETURNS integer
   AS 'MODULE_PATHNAME', 'postal_code_part_end'
   LANGUAGE C STABLE STRICT;
COMMENT ON FUNCTION postal_code_part_end(postal_code, text) IS
   'How many characters of the code (not counting "CC-") there are up to and including the named part; NULL if the code has no such part. What prefix_of() cuts at.';

CREATE FUNCTION prefix_of(postal_code, text)
   RETURNS postal_code_range
   LANGUAGE sql STABLE STRICT
   AS 'SELECT postal_prefix(left($1::text, 3 + postal_code_part_end($1, $2)))';
COMMENT ON FUNCTION prefix_of(postal_code, text) IS
   'Everything up to and including the named part, as the range of every code that starts that way: prefix_of(''GB-SW1A 1AA'', ''district'') is the range of GB-SW1A, which is Royal Mail''s district (part() gives the piece, ''1A''). Usable with <@, indexable like postal_prefix(), and groupable. NULL if the code has no such part.';

-- ---- the same parts for the UK type ---------------------------------------------------------------------
-- postcode has the four parts postal_code gives GB -- area, district, sector, walk, the pieces to_char()'s A D S W
-- give -- read straight from its fields, so these are IMMUTABLE (they can be indexed) and need no table. This is
-- what to_char(postcode, text) is replaced by. A value that is not valid (a range bound that renders '?') has no
-- parts and gives NULL, as ::text does.
--
-- Note: with two types having part(), parts() and prefix_of(), a bare string literal is ambiguous
-- (part('SW1A 1AA', 'area') -> "function part(unknown, unknown) is not unique"). Columns need nothing; a literal
-- needs a cast: part('SW1A 1AA'::postcode, 'area'). to_char() has always been the same.
CREATE FUNCTION part(postcode, text)
   RETURNS text
   AS 'MODULE_PATHNAME', 'postcode_part'
   LANGUAGE C IMMUTABLE STRICT;
COMMENT ON FUNCTION part(postcode, text) IS
   'The named piece of a UK postcode: area (SW), district (1A), sector (1) or walk (AA) for SW1A 1AA -- what to_char(pc, ''A''), ''D'', ''S'' and ''W'' give. NULL for a value that is not valid.';

CREATE FUNCTION parts(postcode)
   RETURNS jsonb
   AS 'MODULE_PATHNAME', 'postcode_parts_json'
   LANGUAGE C IMMUTABLE STRICT;
COMMENT ON FUNCTION parts(postcode) IS
   'All four parts of a UK postcode as jsonb: {"area": "SW", "district": "1A", "sector": "1", "walk": "AA"} (jsonb orders its keys itself).';

CREATE FUNCTION prefix_of(postcode, text)
   RETURNS text
   AS 'MODULE_PATHNAME', 'postcode_prefix_of'
   LANGUAGE C IMMUTABLE STRICT;
COMMENT ON FUNCTION prefix_of(postcode, text) IS
   'Everything up to and including the named part, as the text the % operator takes: prefix_of(''SW1A 1AA''::postcode, ''district'') is ''SW1A'', Royal Mail''s district, so pc % prefix_of(x, ''sector'') finds the postcodes in x''s sector. What to_char(pc, ''AD''), ''AD S'' and ''AD SW'' give.';

-- ---- the parts of the compiled formats --------------------------------------------------------------------
-- The compiled formats keep their codes in their own layouts, but their text is canonical, so a pattern over
-- that text is enough to split it. These patterns are used only to split codes that are already valid, so they
-- need not refuse everything the format refuses (the district's letters in GB depend on the area, for one);
-- test_parts_gb.c checks the GB one against the format, code by code.
CREATE TABLE postal_code_format_parts (
   format_name text PRIMARY KEY REFERENCES postal_code_formats(name),
   pattern     text NOT NULL
);
COMMENT ON TABLE postal_code_format_parts IS
   'The named parts of the compiled formats, as a regular expression over the canonical text of a code without its "CC-". Maintained by this extension''s upgrade scripts; a country using a format gets its parts. FR, CZ and LU have none: their codes are one undivided number.';

INSERT INTO postal_code_format_parts (format_name, pattern) VALUES
   ('GB', $p$(?<area>(?:AB|AL|B|BA|BB|BD|BF|BH|BL|BN|BR|BS|BT|BX|CA|CB|CF|CH|CM|CO|CR|CT|CV|CW|DA|DD|DE|DG|DH|DL|DN|DT|DY|E|EC|EH|EN|EX|FK|FY|G|GL|GU|GX|GY|HA|HD|HG|HP|HR|HS|HU|HX|IG|IM|IP|IV|JE|KA|KT|KW|KY|L|LA|LD|LE|LL|LN|LS|LU|M|ME|MK|ML|N|NE|NG|NN|NP|NR|NW|OL|OX|PA|PE|PH|PL|PO|PR|RG|RH|RM|S|SA|SE|SG|SK|SL|SM|SN|SO|SP|SR|SS|ST|SW|SY|TA|TD|TF|TN|TQ|TR|TS|TW|UB|W|WA|WC|WD|WF|WN|WR|WS|WV|YO|ZE))(?<district>\d[A-Z\d]?)( (?<sector>\d)(?<walk>[A-Z]{2}))?$p$),
   ('US', $p$(?<zip5>\d{5})(-(?<plus4>\d{4}))?$p$),
   ('CA', $p$(?<fsa>[A-Z]\d[A-Z])( (?<ldu>\d[A-Z]\d))?$p$),
   ('IE', $p$(?<routing_key>[A-Z]\d[\dW]|D6W)( (?<unique_id>[A-Z\d]{4}))?$p$),
   ('BR', $p$(?<region>\d)(?<area>\d{4})(-(?<suffix>\d{3}))?$p$);

-- ---- schemes defined by a list of codes ------------------------------------------------------------------
-- A scheme whose valid codes are a published list (SIC, SOC, NUTS, ICD-10) is better given as that list than as a
-- pattern: the automaton is built straight from the codes, the smallest there is for them, with no pattern text and none of
-- a pattern's limits (see LIST_SCHEMES.md). A list is a language like any other -- same ranks, ranges, locks, outcode --
-- stored in its own table and read back through postal_code_languages, where kind says which it is.
--
--   SELECT add_country_list('XS', ARRAY['01110', '01120', ...]);
--   SELECT add_country_list_from('XS', 'SELECT sic FROM my_sic_table',
--                                '/(?<division>\d{2})(?<group>\d)(?<class>\d)(?<subclass>\d)/');
ALTER TABLE postal_code_languages
   ADD COLUMN kind text NOT NULL DEFAULT 'pattern' CHECK (kind IN ('pattern', 'list')),
   ADD COLUMN parts_pattern text,
   ADD CONSTRAINT postal_code_languages_kind_fields CHECK
      ((kind = 'pattern' AND pattern <> '' AND parts_pattern IS NULL) OR (kind = 'list' AND pattern = ''));
COMMENT ON COLUMN postal_code_languages.kind IS
   '''pattern'': pattern is the regular expression the codes are decoded with. ''list'': the codes are the rows of postal_code_list_codes, pattern is empty and source says how many.';
COMMENT ON COLUMN postal_code_languages.parts_pattern IS
   'For a list: a pattern of its own that only splits a code into named parts (a list has no pattern to name them in). It must accept every code in the list. NULL if the list names no parts.';

CREATE TABLE postal_code_list_codes (
   iso2    text NOT NULL,
   version smallint NOT NULL,
   code    text COLLATE "C" NOT NULL,
   PRIMARY KEY (iso2, version, code)
);
COMMENT ON TABLE postal_code_list_codes IS
   'The codes of the languages whose kind is ''list'', in byte order. A language''s codes never change (stored values are decoded with them): rows cannot be updated or deleted. Add them with add_country_list(), not by hand. Included in pg_dump. There is no foreign key to postal_code_languages, because a restore may load the two in either order.';
SELECT pg_extension_config_dump('postal_code_list_codes', '');

CREATE FUNCTION postal_code_list_codes_are_permanent()
   RETURNS trigger
   LANGUAGE plpgsql AS $$
BEGIN
   RAISE EXCEPTION 'postal_code_list_codes rows are permanent: stored postal_code values are decoded with them'
      USING HINT = 'to change a country''s codes, add a new list with add_country_list()';
END;
$$;
CREATE TRIGGER postal_code_list_codes_permanent_row
   BEFORE UPDATE OR DELETE ON postal_code_list_codes
   FOR EACH ROW EXECUTE FUNCTION postal_code_list_codes_are_permanent();
CREATE TRIGGER postal_code_list_codes_permanent_truncate
   BEFORE TRUNCATE ON postal_code_list_codes
   FOR EACH STATEMENT EXECUTE FUNCTION postal_code_list_codes_are_permanent();
-- a list added in a transaction that rolls back must not linger in other backends' caches
CREATE TRIGGER postal_code_list_codes_changed
   AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON postal_code_list_codes
   FOR EACH STATEMENT EXECUTE FUNCTION postal_code_formats_changed();

CREATE FUNCTION postal_code_list_check(text[])
   RETURNS integer
   AS 'MODULE_PATHNAME', 'postal_code_list_check'
   LANGUAGE C IMMUTABLE STRICT;
COMMENT ON FUNCTION postal_code_list_check(text[]) IS
   'Checks a list of codes, sorted in byte order, and returns how many states its automaton has. An error says where the list goes wrong: a code that is empty, over 40 characters, not upper case printable ASCII, out of order or repeated, or a list needing more than 32767 states.';

CREATE FUNCTION postal_code_list_check_parts(text[], text)
   RETURNS void
   AS 'MODULE_PATHNAME', 'postal_code_list_check_parts'
   LANGUAGE C IMMUTABLE STRICT;
COMMENT ON FUNCTION postal_code_list_check_parts(text[], text) IS
   'Checks the pattern that names the parts of a list: it must name at least one part, accept every code in the list and split each one a single way. The error names the first code that fails.';

CREATE FUNCTION postal_code_language_denotes_list(text, integer, text[])
   RETURNS boolean
   AS 'MODULE_PATHNAME', 'postal_code_language_denotes_list'
   LANGUAGE C STABLE STRICT;
COMMENT ON FUNCTION postal_code_language_denotes_list(text, integer, text[]) IS
   'Whether a country''s stored language (a pattern or a list), given its version, denotes exactly the codes of a sorted list.';

CREATE FUNCTION postal_code_language_denotes_pattern(text, integer, text)
   RETURNS boolean
   AS 'MODULE_PATHNAME', 'postal_code_language_denotes_pattern'
   LANGUAGE C STABLE STRICT;
COMMENT ON FUNCTION postal_code_language_denotes_pattern(text, integer, text) IS
   'Whether a country''s stored language (a pattern or a list), given its version, denotes exactly the codes of a regular expression.';

UPDATE postal_code_formats SET description =
   'A language of the country''s own: a pattern (a regular expression or template) or a list of codes, in postal_code_languages'
   WHERE name = 'pattern';

CREATE VIEW postal_code_parts AS
   SELECT cf.iso2, cf.format_name AS format, n.ord::integer AS ord, n.name
   FROM postal_code_country_formats cf
   JOIN postal_code_format_parts fp ON fp.format_name = cf.format_name
   CROSS JOIN LATERAL unnest(postal_code_pattern_part_names(fp.pattern)) WITH ORDINALITY AS n(name, ord)
   UNION ALL
   SELECT l.iso2, 'pattern v' || l.version, n.ord::integer, n.name
   FROM postal_code_languages l
   CROSS JOIN LATERAL unnest(postal_code_pattern_part_names(CASE WHEN l.kind = 'pattern' THEN l.pattern END)) WITH ORDINALITY AS n(name, ord)
   UNION ALL
   SELECT l.iso2, 'list v' || l.version, n.ord::integer, n.name
   FROM postal_code_languages l
   CROSS JOIN LATERAL unnest(postal_code_pattern_part_names(CASE WHEN l.kind = 'list' THEN l.parts_pattern END)) WITH ORDINALITY AS n(name, ord);
COMMENT ON VIEW postal_code_parts IS
   'The named parts each country''s postal codes have, in order: part(code, name) returns the piece, prefix_of(code, name) everything up to and including it. format is the compiled format, or the version of the country''s pattern. Countries not listed have no named parts.';

-- ---- names are labels; the set of codes is permanent -----------------------------------------------------
-- A language row still cannot change what it means: stored values are decoded with it, and a code's rank
-- depends only on the SET of codes the pattern denotes. So a row's pattern may be rewritten to any other pattern
-- that denotes exactly the same set (postal_code_same_codes) -- which is how a country's parts are named, renamed
-- or unnamed without a new version, which would create different values.
CREATE OR REPLACE FUNCTION postal_code_languages_are_permanent()
   RETURNS trigger
   LANGUAGE plpgsql AS $$
BEGIN
   IF TG_OP = 'UPDATE'
      AND NEW.iso2 = OLD.iso2 AND NEW.version = OLD.version AND NEW.builtin = OLD.builtin
      AND NEW.created_at = OLD.created_at AND NEW.kind = OLD.kind THEN
      IF OLD.kind = 'pattern' THEN
         IF NEW.pattern <> OLD.pattern AND postal_code_same_codes(NEW.pattern, OLD.pattern) THEN
            RETURN NEW;
         END IF;
      ELSE
         -- a list: its codes are in postal_code_list_codes and never change; only the pattern naming its parts can
         IF NEW.pattern = OLD.pattern AND NEW.parts_pattern IS DISTINCT FROM OLD.parts_pattern THEN
            IF NEW.parts_pattern IS NOT NULL THEN
               PERFORM postal_code_pattern_part_names(NEW.parts_pattern);     -- an error if it is not a valid pattern
            END IF;
            RETURN NEW;
         END IF;
      END IF;
   END IF;
   RAISE EXCEPTION 'postal_code_languages rows are permanent: stored postal_code values are decoded with them'
      USING HINT = 'to change a country''s rules, add a new language with add_country_template() or add_country_list(); a pattern can only be rewritten in place to one that denotes exactly the same codes, as when naming its parts, and a list can only have its parts renamed';
END;
$$;

CREATE OR REPLACE FUNCTION add_country_template(cc text, spec text)
   RETURNS void
   LANGUAGE plpgsql AS $$
DECLARE
   norm_cc text := upper(cc);
   re      text;
   cur     record;
   v       smallint;
   note    text;
BEGIN
   IF norm_cc !~ '^[A-Z]{2}$' THEN
      RAISE EXCEPTION 'country code must be exactly two letters, got %', cc;
   END IF;
   re := postal_code_pattern_check(spec);
   note := postal_code_parts_check(re);          -- an error if some code could be split into its parts two ways
   IF note IS NOT NULL THEN
      RAISE NOTICE '%', note;
   END IF;

   -- one writer at a time, so two sessions cannot be given the same version
   LOCK TABLE postal_code_languages IN SHARE ROW EXCLUSIVE MODE;

   SELECT l.version, l.source, l.pattern, l.builtin, l.kind INTO cur FROM postal_code_languages l WHERE l.iso2 = norm_cc ORDER BY l.version DESC LIMIT 1;
   IF cur.version IS NOT NULL AND postal_code_language_denotes_pattern(norm_cc, cur.version, re) THEN
      -- the same codes, however written or named: never a new version (which would make different values)
      IF cur.kind = 'list' THEN
         RAISE NOTICE 'the language of % is a list of exactly these codes and is kept as it is', norm_cc;
      ELSIF cur.pattern <> re AND cur.source <> spec THEN   -- (the very spec it was made from: nothing to say, as in 2.0.x)
         IF cur.builtin THEN
            -- a built-in language comes back with the extension, so it is never edited
            RAISE NOTICE 'the built-in language of % already denotes these codes and is kept as it is, with its own part names', norm_cc;
         ELSE
            UPDATE postal_code_languages SET source = spec, pattern = re WHERE iso2 = norm_cc AND version = cur.version;
         END IF;
      END IF;
   ELSE
      -- a different set of codes: the country's next language
      v := coalesce(cur.version, 0) + 1;
      IF v > 51 THEN
         RAISE EXCEPTION 'country % already has 51 postal_code languages, the most there is room for', norm_cc;
      END IF;
      INSERT INTO postal_code_languages (iso2, version, source, pattern) VALUES (norm_cc, v, spec, re);
   END IF;

   PERFORM add_country_format(norm_cc, 'pattern');
END;
$$;
COMMENT ON FUNCTION add_country_template(text, text) IS
   'Give a country a pattern for its postal codes: add_country_template(''PL'', ''NN-NNN'') or add_country_template(''TW'', ''/\d{3}(-\d{2,3})?/''). A template is N (a digit), A (a letter), X (either), a space or hyphen, and [ ] around an optional part; a regular expression is written between slashes (see postal_code_pattern.h) and may name parts of the code with (?<name>...). It defines the whole set of the country''s codes. If the country already has a different set of codes this adds a new version of it; values already stored keep the one they were written with. The same codes written or named differently never make a new version: they relabel the current one, or, if it is built in, leave it as it is. A pattern whose parts could split some code two ways is refused.';

-- ---- giving a country a list ------------------------------------------------------------------------------
CREATE FUNCTION add_country_list(cc text, codes text[], parts_regex text DEFAULT NULL)
   RETURNS void
   LANGUAGE plpgsql AS $$
DECLARE
   norm_cc text := upper(cc);
   sorted  text[];
   n       integer;
   parts_re text;
   dup     text;
   cur     record;
   v       smallint;
BEGIN
   IF norm_cc !~ '^[A-Z]{2}$' THEN
      RAISE EXCEPTION 'country code must be exactly two letters, got %', cc;
   END IF;
   IF codes IS NULL OR cardinality(codes) = 0 THEN
      RAISE EXCEPTION 'a list needs at least one code';
   END IF;
   -- the order you give them in does not matter: they are put in byte order, the order a code ranks by
   SELECT array_agg(c ORDER BY c COLLATE "C") INTO sorted FROM unnest(codes) AS c;
   n := cardinality(sorted);
   SELECT c INTO dup FROM unnest(sorted) AS c GROUP BY c HAVING count(*) > 1 ORDER BY c COLLATE "C" LIMIT 1;
   IF dup IS NOT NULL THEN
      RAISE EXCEPTION 'the code "%" is in the list more than once', dup;
   END IF;
   PERFORM postal_code_list_check(sorted);        -- an error, with the position, if a code is empty, too long, not upper case, or repeated
   IF parts_regex IS NOT NULL THEN
      -- written between slashes, as for add_country_template(); stored without them
      parts_re := CASE WHEN parts_regex ~ '^/.+/$' THEN substr(parts_regex, 2, length(parts_regex) - 2) ELSE parts_regex END;
      PERFORM postal_code_list_check_parts(sorted, parts_re);
   END IF;

   -- one writer at a time, so two sessions cannot be given the same version
   LOCK TABLE postal_code_languages IN SHARE ROW EXCLUSIVE MODE;

   SELECT l.version, l.kind, l.parts_pattern INTO cur FROM postal_code_languages l WHERE l.iso2 = norm_cc ORDER BY l.version DESC LIMIT 1;
   IF cur.version IS NOT NULL AND postal_code_language_denotes_list(norm_cc, cur.version, sorted) THEN
      -- the same codes: never a new version (which would make different values). The names of the parts are labels.
      IF cur.kind = 'list' THEN
         IF cur.parts_pattern IS DISTINCT FROM parts_re THEN
            UPDATE postal_code_languages SET parts_pattern = parts_re WHERE iso2 = norm_cc AND version = cur.version;
         END IF;
      ELSE
         RAISE NOTICE 'the language of % is a pattern that denotes exactly these codes and is kept as it is', norm_cc;
      END IF;
   ELSE
      -- different codes: the country's next language
      v := coalesce(cur.version, 0) + 1;
      IF v > 51 THEN
         RAISE EXCEPTION 'country % already has 51 postal_code languages, the most there is room for', norm_cc;
      END IF;
      INSERT INTO postal_code_languages (iso2, version, source, pattern, kind, parts_pattern)
         VALUES (norm_cc, v, 'list of ' || n || ' codes', '', 'list', parts_re);
      INSERT INTO postal_code_list_codes (iso2, version, code) SELECT norm_cc, v, c FROM unnest(sorted) AS c;
   END IF;

   PERFORM add_country_format(norm_cc, 'pattern');
END;
$$;
COMMENT ON FUNCTION add_country_list(text, text[], text) IS
   'Give a country a list of codes: add_country_list(''XS'', ARRAY[''01110'', ''01120'', ...], ''/(?<division>\d{2})(?<rest>\d{3})/''). The codes are all there are (upper case, printable ASCII, up to 40 characters, no repeats) and are ranked in byte order, so prefix ranges and indexes work as for a pattern. The optional last argument names the parts of a code (a regular expression, only for splitting: it must accept every code in the list). Giving the same codes again changes nothing except the part names; different codes make the country''s next language, and values already stored keep the one they were written with.';

CREATE FUNCTION add_country_list_from(cc text, query text, parts_regex text DEFAULT NULL)
   RETURNS void
   LANGUAGE plpgsql AS $$
DECLARE
   codes text[];
BEGIN
   EXECUTE format('SELECT array_agg(c) FROM (%s) AS q(c)', query) INTO codes;
   PERFORM add_country_list(cc, codes, parts_regex);
END;
$$;
COMMENT ON FUNCTION add_country_list_from(text, text, text) IS
   'add_country_list() with the codes taken from a query that returns one column: add_country_list_from(''XS'', ''SELECT sic FROM my_sic_table'', ...). The query runs with your own privileges.';

-- ---- deprecation ------------------------------------------------------------------------------------------
COMMENT ON FUNCTION to_char(postcode, text) IS
   'DEPRECATED since 2.1: cutting a postcode up by format letters is not a sensible way to take it apart (A, D, S and W give the pieces, not Royal Mail''s district and sector). Use part() and prefix_of(), which take a postcode as well as a postal_code (A, D, S, W are part(pc, ''area''), ''district'', ''sector'', ''walk''; AD is prefix_of(pc, ''district'')); ::text renders the text form. Still works, and will not be removed within 2.x.';

-- BEGIN generated by tools/world_formats.py --parts-sql -- edit that, not this
-- Name the parts of the built-in patterns. A language is permanent, but its names are labels: the trigger lets a
-- pattern be rewritten only to one that denotes exactly the same codes, so a slip here stops the upgrade.
-- Only patterns with real structure are named; the others are one undivided number, or only a display grouping, and have no parts.
-- AR: province letter + postal number + the three letters naming the face of the block; the old four-digit code has no parts
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<province>[ABCDEFGHJKLMNPQRSTUVWXYZ])(?<number>\d{4})(?<face>[A-Z]{3})?|\d{4}/$p$)
   WHERE iso2 = 'AR' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<zip5>96799)(-(?<plus4>[1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/$p$)
   WHERE iso2 = 'AS' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<prefix>[A-Z]{2}) (?<suffix>[0-9A-Z]{2})/$p$)
   WHERE iso2 = 'BM' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<prefix>[1-9]\d{2})-(?<suffix>\d{4})/$p$)
   WHERE iso2 = 'CL' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<base>\d{6})(-(?<extension>\d{3}))?/$p$)
   WHERE iso2 = 'CO' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<base>\d{5})(-(?<extension>\d{4}))?/$p$)
   WHERE iso2 = 'CR' AND version = 1 AND builtin;
-- ES: the first two digits are the province (01-52)
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<province>0[1-9]|[1-4]\d|5[0-2])(?<local>\d{3})/$p$)
   WHERE iso2 = 'ES' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<zip5>9694[1-4])(-(?<plus4>[1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/$p$)
   WHERE iso2 = 'FM' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<zip5>969\d{2})(-(?<plus4>[1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/$p$)
   WHERE iso2 = 'GU' AND version = 1 AND builtin;
-- IR: the ten-digit code, whose first five digits are a locality block, written with an optional hyphen
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<base>\d{5})(-(?<extension>\d{5}))?/$p$)
   WHERE iso2 = 'IR' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<prefix>\d{3})-(?<suffix>\d{4})/$p$)
   WHERE iso2 = 'JP' AND version = 1 AND builtin;
-- KY: KY1, KY2, KY3 are Grand Cayman, Cayman Brac and Little Cayman
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<island>[1-3])-(?<number>\d{4})/$p$)
   WHERE iso2 = 'KY' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<base>\d{4})( (?<extension>\d{4}))?/$p$)
   WHERE iso2 = 'LB' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<zip5>969[67]\d)(-(?<plus4>[1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/$p$)
   WHERE iso2 = 'MH' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<zip5>9695[0-2])(-(?<plus4>[1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/$p$)
   WHERE iso2 = 'MP' AND version = 1 AND builtin;
-- MT: a three-letter locality code, then a number
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<locality>[A-Z]{3})( (?<number>\d{4}))?/$p$)
   WHERE iso2 = 'MT' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<base>\d{4})(-(?<extension>\d{2}))?/$p$)
   WHERE iso2 = 'MZ' AND version = 1 AND builtin;
-- NL: four digits, then two letters
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<digits>[1-9]\d{3})( (?<letters>[A-EGHJ-NPRTVWXZ][A-EGHJ-NPRSTVWXZ]|S[BCEGHJ-NPRTVWXZ]))?/$p$)
   WHERE iso2 = 'NL' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<prefix>\d{2})-(?<suffix>\d{3})/$p$)
   WHERE iso2 = 'PL' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<zip5>00[6-9]\d{2})(-(?<plus4>[1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/$p$)
   WHERE iso2 = 'PR' AND version = 1 AND builtin;
-- PT: the four-digit base (CP4) and the optional three-digit extension (CP3)
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<base>[1-9]\d{3})(-(?<extension>\d{3}))?/$p$)
   WHERE iso2 = 'PT' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<zip5>96940)(-(?<plus4>[1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/$p$)
   WHERE iso2 = 'PW' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<base>\d{5})(-(?<extension>\d{4}))?/$p$)
   WHERE iso2 = 'SA' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<prefix>[A-Z]{2}) (?<suffix>\d{5})/$p$)
   WHERE iso2 = 'SO' AND version = 1 AND builtin;
-- TR: the first two digits are the province (01-81; 99 is the north of Cyprus)
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<province>0[1-9]|[1-7]\d|8[01]|99)(?<local>\d{3})/$p$)
   WHERE iso2 = 'TR' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<base>\d{3})(-(?<extension>\d{2,3}))?/$p$)
   WHERE iso2 = 'TW' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<zip5>96898)(-(?<plus4>[1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/$p$)
   WHERE iso2 = 'UM' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<base>\d{4})(-(?<extension>[A-Z]))?/$p$)
   WHERE iso2 = 'VE' AND version = 1 AND builtin;
UPDATE postal_code_languages SET pattern = postal_code_pattern_check($p$/(?<zip5>008\d{2})(-(?<plus4>[1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?/$p$)
   WHERE iso2 = 'VI' AND version = 1 AND builtin;
-- END generated
