-- 2.0.0 adds postal_code, a 64-bit type for any country's postal
-- code (country:10 | format:6 | national payload:48 -- see
-- postal_code.h). postcode and dps are entirely unchanged: existing
-- columns, indexes and binary data using them are unaffected by this
-- upgrade. GB postal data can keep using the original postcode type
-- indefinitely -- postal_code is additive, not a replacement.
--
-- Country sorts as ISO 3166-1 alpha-2 text order (the two letters
-- are packed directly into the country field, not looked up via an
-- index into a table -- see postal_code.h for why that avoids the
-- ordering hazard an appended area code has in areas.h). Within a
-- country, a "more precise variant" of the same underlying code
-- (e.g. a bare US ZIP5 vs. that same ZIP5 with a +4, or a Canadian
-- FSA-only value vs. the same FSA with a full LDU) interleaves
-- immediately before its more specific children rather than being
-- grouped apart from them by format.
--
-- Text form follows the UPU recommendation: the ISO 3166-1 alpha-2
-- country, a hyphen, then the national code -- 'US-90210-1234',
-- 'CA-K1A 0B1', 'GB-SW1A 1AA'. The country is always two characters,
-- so the first hyphen is the delimiter even where the national code has
-- hyphens of its own (US ZIP+4, BR CEP).
--
-- Where a country has a distinct outcode/incode structure (GB, IE, CA,
-- US) the outcode alone is a complete, valid value -- GeoNames' own GB,
-- IE and CA rows are overwhelmingly exactly that. Where the leading
-- digits are only implicitly an outcode (FR, CZ, LU) the full code is
-- required.
--
-- Formats: US, CA, FR, BR, CZ, LU, GB, IE. Which country uses which
-- format is data (postal_code_country_formats, below), not code: add a
-- country to an existing format with add_country_format(); only a
-- genuinely new format shape needs C (postal_code_fmt.c).

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

-- is_valid(): does this text parse as a postal_code at all? Never raises
-- for bad input (false); a NULL postcode gives NULL (so it works in a CHECK
-- constraint, which lets NULLs through). Same two forms as the constructors:
--   is_valid('FR-75054 CEDEX 01')    is_valid('75054 CEDEX 01', 'FR')
-- It is exactly "to_postal_code(...) IS NOT NULL" -- every per-country
-- restriction (Canadian excluded letters, Eircode's alphabet, ZIP+4 0000,
-- ...) is enforced by the same parser that enforces it at ingest, so the
-- two can't disagree. A country assigned to a format this build doesn't
-- have is a configuration fault and still raises rather than saying false.
CREATE FUNCTION is_valid(text)
   RETURNS boolean
   LANGUAGE sql STABLE STRICT
   AS 'SELECT to_postal_code($1) IS NOT NULL';

CREATE FUNCTION is_valid(postcode text, cc text)
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
--   bound, never a postcode (is_valid('US-~') is false), and it is what makes
--   `pc < upper_bound(...)` right at the top of a country too.
CREATE FUNCTION lower_bound(text)
   RETURNS postal_code
   AS 'MODULE_PATHNAME', 'postal_code_lower_bound'
   LANGUAGE C STABLE STRICT;

CREATE FUNCTION upper_bound(text)
   RETURNS postal_code
   AS 'MODULE_PATHNAME', 'postal_code_upper_bound'
   LANGUAGE C STABLE STRICT;

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
   'Undo add_country_format(): after this, parsing "CC-..."/postal_code(..., cc) for that country raises rather than resolving to whatever format it used to have. Existing stored values for that country are unaffected -- see postal_code_country_formats'' own comment.';


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
-- depend on postal_code_country_formats, and the trigger below invalidates
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

CREATE FUNCTION postal_code_formats_changed()
   RETURNS trigger
   AS 'MODULE_PATHNAME'
   LANGUAGE C;

CREATE TRIGGER postal_code_country_formats_changed
   AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON postal_code_country_formats
   FOR EACH STATEMENT EXECUTE FUNCTION postal_code_formats_changed();
