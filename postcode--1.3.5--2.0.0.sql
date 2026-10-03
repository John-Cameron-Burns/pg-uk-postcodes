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
-- the formats these refer to that a user created (templates); the built-in ones come with the extension
SELECT pg_extension_config_dump('postal_code_formats',
   $$WHERE name LIKE 'template:%' AND name NOT IN (SELECT 'template:' || template FROM postal_code_templates WHERE builtin)$$);

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
      RAISE EXCEPTION 'unknown postal_code format %, must be one of: % (or use add_country_template() for a new shape)',
         format_name, (SELECT string_agg(name, ', ' ORDER BY name) FROM postal_code_formats WHERE name NOT LIKE 'template:%');
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


-- ---- templated formats -------------------------------------------------------
-- A country whose postal codes are just fixed-width groups of digits and
-- letters needs no C encoder: it can be assigned a TEMPLATE, e.g.
--
--   SELECT add_country_template('PL', 'NN-NNN');
--   SELECT add_country_template('NL', 'NNNN AA');
--   SELECT add_country_template('DE', 'NNNNN');
--
-- N is a digit, A a letter, X either; ' ' and '-' are separators (always
-- written, optional on input); one optional [ ] group may end the template,
-- and without it the code before the group (the "outcode") is a value of its
-- own, so 'NNNNN[-NNNN]' is ZIP5 with an optional +4. See
-- postal_code_template.h for the rules and the encoding.
--
-- Stored values carry the template's SLOT as their format tag, and read it back
-- through this table, so a template can never change once it has a slot
-- (the trigger below refuses): to change a country's format, assign it a
-- new template; values already written still decode under the old one.
-- Slots 12..62 are available (the world's countries use about a third of
-- them, in the generated block below), the same template is only ever stored
-- once, and countries sharing a shape share a slot.
CREATE TABLE postal_code_templates (
   slot       smallint PRIMARY KEY CHECK (slot BETWEEN 12 AND 62),
   template   text NOT NULL UNIQUE,
   builtin    boolean NOT NULL DEFAULT false,
   created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE postal_code_templates IS
   'The templated postal_code formats in use: the slot is the format tag stored in every value written under it, so rows are permanent -- they cannot be updated or deleted. Add them with add_country_template(), not by hand. The ones you add are included in pg_dump, because values cannot be read without them; the builtin ones come with the extension.';
SELECT pg_extension_config_dump('postal_code_templates', 'WHERE NOT builtin');

CREATE FUNCTION postal_code_template_check(text)
   RETURNS text
   AS 'MODULE_PATHNAME', 'postal_code_template_check'
   LANGUAGE C IMMUTABLE STRICT;
COMMENT ON FUNCTION postal_code_template_check(text) IS
   'Validates a postal_code template and returns it in canonical form, or raises an error saying what is wrong with it.';

CREATE FUNCTION postal_code_templates_are_permanent()
   RETURNS trigger
   LANGUAGE plpgsql AS $$
BEGIN
   RAISE EXCEPTION 'postal_code_templates rows are permanent: stored postal_code values are decoded with them'
      USING HINT = 'to change a country''s format, assign it a new template with add_country_template()';
END;
$$;
CREATE TRIGGER postal_code_templates_permanent_row
   BEFORE UPDATE OR DELETE ON postal_code_templates
   FOR EACH ROW EXECUTE FUNCTION postal_code_templates_are_permanent();
CREATE TRIGGER postal_code_templates_permanent_truncate
   BEFORE TRUNCATE ON postal_code_templates
   FOR EACH STATEMENT EXECUTE FUNCTION postal_code_templates_are_permanent();

CREATE FUNCTION add_country_template(cc text, tpl text)
   RETURNS void
   LANGUAGE plpgsql AS $$
DECLARE
   spec text := postal_code_template_check(tpl);
   free_slot smallint;
BEGIN
   -- one writer at a time, so two sessions cannot be given the same slot
   LOCK TABLE postal_code_templates IN SHARE ROW EXCLUSIVE MODE;

   SELECT t.slot INTO free_slot FROM postal_code_templates t WHERE t.template = spec;
   IF free_slot IS NULL THEN
      SELECT min(g) INTO free_slot FROM generate_series(12, 62) g
      WHERE g NOT IN (SELECT t.slot FROM postal_code_templates t);
      IF free_slot IS NULL THEN
         RAISE EXCEPTION 'all 51 postal_code template slots are in use';
      END IF;
      INSERT INTO postal_code_templates (slot, template) VALUES (free_slot, spec);
   END IF;

   INSERT INTO postal_code_formats (name, description)
   VALUES ('template:' || spec, 'Template ' || spec)
   ON CONFLICT (name) DO NOTHING;

   PERFORM add_country_format(cc, 'template:' || spec);
END;
$$;
COMMENT ON FUNCTION add_country_template(text, text) IS
   'Assign (or reassign) a country to a templated format, creating the template if it is new: add_country_template(''PL'', ''NN-NNN''). N is a digit, A a letter, X either; '' '' and ''-'' are separators; one optional [ ] group may end the template (''NNNNN[-NNNN]''). Values already stored for the country keep the format they were written with.';

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
-- Template slots are permanent: this list only ever grows (append, never reorder).
INSERT INTO postal_code_templates (slot, template, builtin) VALUES
   (12, 'AA NNNNN', true),
   (13, 'AA XX', true),
   (14, 'AAA NNNN', true),
   (15, 'AAAA NAA', true),
   (16, 'AAANN', true),
   (17, 'AAA[ NNNN]', true),
   (18, 'AANNNN', true),
   (19, 'ANNN', true),
   (20, 'AXNNN[NN]', true),
   (21, 'CC NNNN', true),
   (22, 'CCN-NNNN', true),
   (23, 'CCNN NNN', true),
   (24, 'CCNNN', true),
   (25, 'CCNNNN', true),
   (26, 'CCNNNNN', true),
   (27, 'NN', true),
   (28, 'NN-NNN', true),
   (29, 'NNN', true),
   (30, 'NNN NN', true),
   (31, 'NNN-NNNN', true),
   (32, 'NNNN', true),
   (33, 'NNNNN', true),
   (34, 'NNNNN-NNNNN', true),
   (35, 'NNNNNN', true),
   (36, 'NNNNN[-NNNN]', true),
   (37, 'NNNNN[NN]', true),
   (38, 'NNNNN[N]', true),
   (39, 'NNNN[ AA]', true),
   (40, 'NNNN[ NNNN]', true),
   (41, 'NNNN[-A]', true),
   (42, 'NNNN[-NNN]', true),
   (43, 'NNNN[NN]', true),
   (44, 'NNN[-NNN]', true),
   (45, 'NNN[N]', true),
   (46, 'XNNNN', true),
   (47, 'NNNNN[ NNNNN]', true);
INSERT INTO postal_code_formats (name, description)
   SELECT 'template:' || template, 'Template ' || template FROM postal_code_templates WHERE builtin;
INSERT INTO postal_code_builtin_countries (iso2, format_name) VALUES
   ('AD', 'template:CCNNN'),
   ('AE', 'template:NNNNN[ NNNNN]'),
   ('AF', 'template:NNNN'),
   ('AI', 'template:NNNN'),
   ('AL', 'template:NNNN'),
   ('AM', 'template:NNNN'),
   ('AQ', 'template:AAAA NAA'),
   ('AR', 'template:NNNN'),
   ('AS', 'US'),
   ('AT', 'template:NNNN'),
   ('AU', 'template:NNNN'),
   ('AX', 'template:NNNNN'),
   ('AZ', 'template:CC NNNN'),
   ('BA', 'template:NNNNN'),
   ('BB', 'template:CCNNNNN'),
   ('BD', 'template:NNNN'),
   ('BE', 'template:NNNN'),
   ('BG', 'template:NNNN'),
   ('BH', 'template:NNN[N]'),
   ('BL', 'FR'),
   ('BM', 'template:AA XX'),
   ('BN', 'template:AANNNN'),
   ('BT', 'template:NNNNN'),
   ('BY', 'template:NNNNNN'),
   ('CC', 'template:NNNN'),
   ('CH', 'template:NNNN'),
   ('CL', 'template:NNN-NNNN'),
   ('CN', 'template:NNNNNN'),
   ('CO', 'template:NNNNNN'),
   ('CR', 'template:NNNNN'),
   ('CU', 'template:NNNNN'),
   ('CV', 'template:NNNN'),
   ('CX', 'template:NNNN'),
   ('CY', 'template:NNNN'),
   ('DE', 'template:NNNNN'),
   ('DK', 'template:NNNN'),
   ('DO', 'template:NNNNN'),
   ('DZ', 'template:NNNNN'),
   ('EC', 'template:NNNNNN'),
   ('EE', 'template:NNNNN'),
   ('EG', 'template:NNNNN[NN]'),
   ('ES', 'template:NNNNN'),
   ('ET', 'template:NNNN'),
   ('FI', 'template:NNNNN'),
   ('FK', 'template:AAAA NAA'),
   ('FM', 'US'),
   ('FO', 'template:NNN'),
   ('GE', 'template:NNNN'),
   ('GF', 'FR'),
   ('GH', 'template:AXNNN[NN]'),
   ('GI', 'GB'),
   ('GL', 'template:NNNN'),
   ('GN', 'template:NNN'),
   ('GP', 'FR'),
   ('GR', 'template:NNN NN'),
   ('GS', 'template:AAAA NAA'),
   ('GT', 'template:NNNNN'),
   ('GU', 'US'),
   ('GW', 'template:NNNN'),
   ('HK', 'template:NNNNNN'),
   ('HM', 'template:NNNN'),
   ('HN', 'template:NNNNN'),
   ('HR', 'template:NNNNN'),
   ('HT', 'template:CCNNNN'),
   ('HU', 'template:NNNN'),
   ('ID', 'template:NNNNN'),
   ('IL', 'template:NNNNN[NN]'),
   ('IN', 'template:NNNNNN'),
   ('IO', 'template:AAAA NAA'),
   ('IQ', 'template:NNNNN'),
   ('IR', 'template:NNNNN-NNNNN'),
   ('IS', 'template:NNN'),
   ('IT', 'template:NNNNN'),
   ('JM', 'template:NN'),
   ('JO', 'template:NNNNN'),
   ('JP', 'template:NNN-NNNN'),
   ('KE', 'template:NNNNN'),
   ('KG', 'template:NNNNNN'),
   ('KH', 'template:NNNNNN'),
   ('KN', 'template:CCNNNN'),
   ('KR', 'template:NNNNN'),
   ('KW', 'template:NNNNN'),
   ('KY', 'template:CCN-NNNN'),
   ('KZ', 'template:NNNNNN'),
   ('LA', 'template:NNNNN'),
   ('LB', 'template:NNNN[ NNNN]'),
   ('LC', 'template:CCNN NNN'),
   ('LI', 'template:NNNN'),
   ('LK', 'template:NNNNN'),
   ('LR', 'template:NNNN'),
   ('LS', 'template:NNN'),
   ('LT', 'template:NNNNN'),
   ('LV', 'template:NNNN'),
   ('MA', 'template:NNNNN'),
   ('MC', 'template:NNNNN'),
   ('MD', 'template:NNNN'),
   ('ME', 'template:NNNNN'),
   ('MF', 'FR'),
   ('MG', 'template:NNN'),
   ('MH', 'US'),
   ('MK', 'template:NNNN'),
   ('MM', 'template:NNNNN[NN]'),
   ('MN', 'template:NNNNN'),
   ('MO', 'template:NNNNNN'),
   ('MP', 'US'),
   ('MQ', 'FR'),
   ('MS', 'template:AAA NNNN'),
   ('MT', 'template:AAA[ NNNN]'),
   ('MU', 'template:XNNNN'),
   ('MV', 'template:NNNNN'),
   ('MW', 'template:NNNNNN'),
   ('MX', 'template:NNNNN'),
   ('MY', 'template:NNNNN'),
   ('MZ', 'template:NNNN'),
   ('NA', 'template:NNNNN'),
   ('NC', 'FR'),
   ('NE', 'template:NNNN'),
   ('NF', 'template:NNNN'),
   ('NG', 'template:NNNNNN'),
   ('NI', 'template:NNNNN'),
   ('NL', 'template:NNNN[ AA]'),
   ('NO', 'template:NNNN'),
   ('NP', 'template:NNNNN'),
   ('NR', 'template:AAANN'),
   ('NU', 'template:NNNN'),
   ('NZ', 'template:NNNN'),
   ('OM', 'template:NNN'),
   ('PA', 'template:NNNNN'),
   ('PE', 'template:NNNNN'),
   ('PF', 'FR'),
   ('PG', 'template:NNN'),
   ('PH', 'template:NNNN'),
   ('PK', 'template:NNNNN'),
   ('PL', 'template:NN-NNN'),
   ('PM', 'FR'),
   ('PN', 'template:AAAA NAA'),
   ('PR', 'US'),
   ('PS', 'template:NNN'),
   ('PT', 'template:NNNN[-NNN]'),
   ('PW', 'US'),
   ('PY', 'template:NNNN[NN]'),
   ('RE', 'FR'),
   ('RO', 'template:NNNNNN'),
   ('RS', 'template:NNNNN'),
   ('RU', 'template:NNNNNN'),
   ('SA', 'template:NNNNN[-NNNN]'),
   ('SD', 'template:NNNNN'),
   ('SE', 'template:NNN NN'),
   ('SG', 'template:NNNNNN'),
   ('SH', 'template:AAAA NAA'),
   ('SI', 'template:NNNN'),
   ('SJ', 'template:NNNN'),
   ('SK', 'template:NNN NN'),
   ('SM', 'template:NNNNN'),
   ('SN', 'template:NNNNN'),
   ('SO', 'template:AA NNNNN'),
   ('SV', 'template:NNNN'),
   ('SZ', 'template:ANNN'),
   ('TC', 'template:AAAA NAA'),
   ('TH', 'template:NNNNN'),
   ('TJ', 'template:NNNNNN'),
   ('TM', 'template:NNNNNN'),
   ('TN', 'template:NNNN'),
   ('TR', 'template:NNNNN'),
   ('TT', 'template:NNNNNN'),
   ('TW', 'template:NNN[-NNN]'),
   ('TZ', 'template:NNNNN'),
   ('UA', 'template:NNNNN'),
   ('UM', 'US'),
   ('UY', 'template:NNNNN'),
   ('UZ', 'template:NNNNNN'),
   ('VA', 'template:NNNNN'),
   ('VC', 'template:CCNNNN'),
   ('VE', 'template:NNNN[-A]'),
   ('VG', 'template:CCNNNN'),
   ('VI', 'US'),
   ('VN', 'template:NNNNN[N]'),
   ('WF', 'FR'),
   ('WS', 'template:CCNNNN'),
   ('XK', 'template:NNNNN'),
   ('YT', 'FR'),
   ('ZA', 'template:NNNN'),
   ('ZM', 'template:NNNNN');
INSERT INTO postal_code_iso_countries (iso2, name, basis, note) VALUES
   ('AD', 'Andorra
', 'GeoNames data', NULL),
   ('AE', 'United Arab Emirates
', 'see note', 'no postal code system, but two location schemes: Abu Dhabi has 5-digit area codes (20000 central Abu Dhabi, 23251 Khalifa City, 20014 Yas Island), and Dubai numbers every building with a 10-digit Makani code written NNNNN NNNNN (all 178,171 GeoNames rows are Dubai). One format holds both, so any 5 digits pass. Sharjah''s PCS is not modelled; most UAE addresses give a PO Box, which is rejected'),
   ('AF', 'Afghanistan
', 'Wikipedia', NULL),
   ('AG', 'Antigua and Barbuda
', 'no postal codes', NULL),
   ('AI', 'Anguilla
', 'GeoNames data', NULL),
   ('AL', 'Albania
', 'GeoNames data', NULL),
   ('AM', 'Armenia
', 'Wikipedia', NULL),
   ('AO', 'Angola
', 'no postal codes', NULL),
   ('AQ', 'British Antarctic Territory
', 'Wikipedia', NULL),
   ('AR', 'Argentina
', 'see note', 'NNNN, the minimum and the form GeoNames has; the 1999 ANNNNAAA form (CPA) is not accepted'),
   ('AS', 'American Samoa
', 'GeoNames data', NULL),
   ('AT', 'Austria
', 'GeoNames data', NULL),
   ('AU', 'Australia
', 'GeoNames data', NULL),
   ('AW', 'Aruba
', 'no postal codes', NULL),
   ('AX', 'Åland
', 'GeoNames data', NULL),
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
', 'Wikipedia', NULL),
   ('BM', 'Bermuda
', 'see note', 'AA NN; the second pair is sometimes letters, so X'),
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
', 'GeoNames data', NULL),
   ('CR', 'Costa Rica
', 'GeoNames data', NULL),
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
', 'GeoNames data', NULL),
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
', 'GeoNames data', NULL),
   ('ET', 'Ethiopia
', 'Wikipedia', NULL),
   ('FI', 'Finland
', 'GeoNames data', NULL),
   ('FJ', 'Fiji
', 'no postal codes', NULL),
   ('FK', 'Falkland Islands
', 'GeoNames data', NULL),
   ('FM', 'Micronesia
', 'GeoNames data', NULL),
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
', 'GeoNames data', NULL),
   ('GG', 'Guernsey
', 'built in', NULL),
   ('GH', 'Ghana
', 'Wikipedia', NULL),
   ('GI', 'Gibraltar
', 'see note', 'GX11 1AA, the UK format'),
   ('GL', 'Greenland
', 'GeoNames data', NULL),
   ('GM', 'Gambia
', 'no postal codes', NULL),
   ('GN', 'Guinea
', 'Wikipedia', NULL),
   ('GP', 'Guadeloupe
', 'GeoNames data', NULL),
   ('GQ', 'Equatorial Guinea
', 'no postal codes', NULL),
   ('GR', 'Greece
', 'Wikipedia', NULL),
   ('GS', 'South Georgia and the South Sandwich Islands
', 'GeoNames data', NULL),
   ('GT', 'Guatemala
', 'GeoNames data', NULL),
   ('GU', 'Guam
', 'GeoNames data', NULL),
   ('GW', 'Guinea Bissau
', 'Wikipedia', NULL),
   ('GY', 'Guyana
', 'no postal codes', NULL),
   ('HK', 'Hong Kong
', 'see note', 'no postal codes; 999077 is the placeholder GeoNames carries'),
   ('HM', 'Heard and McDonald Islands
', 'GeoNames data', NULL),
   ('HN', 'Honduras
', 'GeoNames data', NULL),
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
', 'GeoNames data', NULL),
   ('IQ', 'Iraq
', 'Wikipedia', NULL),
   ('IR', 'Iran
', 'Wikipedia', NULL),
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
', 'GeoNames data', NULL),
   ('KW', 'Kuwait
', 'Wikipedia', NULL),
   ('KY', 'Cayman Islands
', 'Wikipedia', NULL),
   ('KZ', 'Kazakhstan
', 'Wikipedia', NULL),
   ('LA', 'Laos
', 'Wikipedia', NULL),
   ('LB', 'Lebanon
', 'Wikipedia', NULL),
   ('LC', 'Saint Lucia
', 'Wikipedia', NULL),
   ('LI', 'Liechtenstein
', 'GeoNames data', NULL),
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
', 'GeoNames data', NULL),
   ('MD', 'Moldova
', 'GeoNames data', NULL),
   ('ME', 'Montenegro
', 'Wikipedia', NULL),
   ('MF', 'Saint Martin
', 'Wikipedia', NULL),
   ('MG', 'Madagascar
', 'Wikipedia', NULL),
   ('MH', 'Marshall Islands
', 'GeoNames data', NULL),
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
', 'GeoNames data', NULL),
   ('MQ', 'Martinique
', 'GeoNames data', NULL),
   ('MR', 'Mauritania
', 'no postal codes', NULL),
   ('MS', 'Montserrat
', 'Wikipedia', NULL),
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
', 'Wikipedia', NULL),
   ('NA', 'Namibia
', 'Wikipedia', NULL),
   ('NC', 'New Caledonia
', 'GeoNames data', NULL),
   ('NE', 'Niger
', 'Wikipedia', NULL),
   ('NF', 'Norfolk Island
', 'GeoNames data', NULL),
   ('NG', 'Nigeria
', 'Wikipedia', NULL),
   ('NI', 'Nicaragua
', 'Wikipedia', NULL),
   ('NL', 'Netherlands
', 'see note', 'NNNN, optionally with the two letters; GeoNames has the four digits only'),
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
', 'see note', 'Wikipedia says NNNN; GeoNames has five digits'),
   ('PE', 'Peru
', 'GeoNames data', NULL),
   ('PF', 'French Polynesia
', 'GeoNames data', NULL),
   ('PG', 'Papua New Guinea
', 'Wikipedia', NULL),
   ('PH', 'Philippines
', 'GeoNames data', NULL),
   ('PK', 'Pakistan
', 'GeoNames data', NULL),
   ('PL', 'Poland
', 'GeoNames data', NULL),
   ('PM', 'Saint Pierre and Miquelon
', 'GeoNames data', NULL),
   ('PN', 'Pitcairn Islands
', 'GeoNames data', NULL),
   ('PR', 'Puerto Rico
', 'GeoNames data', NULL),
   ('PS', 'Palestine
', 'Wikipedia', NULL),
   ('PT', 'Portugal
', 'GeoNames data', NULL),
   ('PW', 'Palau
', 'GeoNames data', NULL),
   ('PY', 'Paraguay
', 'Wikipedia', NULL),
   ('QA', 'Qatar
', 'no postal codes', NULL),
   ('RE', 'Réunion
', 'GeoNames data', NULL),
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
', 'GeoNames data', NULL),
   ('SH', 'Saint Helena, Ascension and Tristan da Cunha
', 'Wikipedia', NULL),
   ('SI', 'Slovenia
', 'GeoNames data', NULL),
   ('SJ', 'Svalbard and Jan Mayen
', 'GeoNames data', NULL),
   ('SK', 'Slovakia
', 'GeoNames data', NULL),
   ('SL', 'Sierra Leone
', 'no postal codes', NULL),
   ('SM', 'San Marino
', 'GeoNames data', NULL),
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
', 'GeoNames data', NULL),
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
', 'GeoNames data', NULL),
   ('TT', 'Trinidad and Tobago
', 'Wikipedia', NULL),
   ('TV', 'Tuvalu
', 'no postal codes', NULL),
   ('TW', 'Taiwan
', 'Wikipedia', NULL),
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
', 'GeoNames data', NULL),
   ('VC', 'Saint Vincent and the Grenadines
', 'Wikipedia', NULL),
   ('VE', 'Venezuela
', 'Wikipedia', NULL),
   ('VG', 'British Virgin Islands
', 'Wikipedia', NULL),
   ('VI', 'U.S. Virgin Islands
', 'GeoNames data', NULL),
   ('VN', 'Vietnam
', 'see note', 'Wikipedia says 5 digits; 6 are in use since 2004; both accepted'),
   ('VU', 'Vanuatu
', 'no postal codes', NULL),
   ('WF', 'Wallis and Futuna
', 'GeoNames data', NULL),
   ('WS', 'Samoa
', 'see note', 'Wikipedia: CCNNNN; the one GeoNames row is American Samoa''s ZIP, filed under the wrong country'),
   ('XK', 'Kosovo
', 'Wikipedia', NULL),
   ('YE', 'Yemen
', 'no postal codes', NULL),
   ('YT', 'Mayotte
', 'GeoNames data', NULL),
   ('ZA', 'South Africa
', 'GeoNames data', NULL),
   ('ZM', 'Zambia
', 'Wikipedia', NULL),
   ('ZW', 'Zimbabwe
', 'no postal codes', NULL);
-- END generated

CREATE VIEW postal_code_world AS
   SELECT i.iso2, i.name, f.format_name AS format, COALESCE(f.builtin, false) AS builtin, i.basis, i.note
   FROM postal_code_iso_countries i
   LEFT JOIN postal_code_country_formats f ON f.iso2 = i.iso2
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

CREATE FUNCTION postal_code_formats_changed()
   RETURNS trigger
   AS 'MODULE_PATHNAME'
   LANGUAGE C;

CREATE TRIGGER postal_code_user_countries_changed
   AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON postal_code_user_countries
   FOR EACH STATEMENT EXECUTE FUNCTION postal_code_formats_changed();
-- ... and likewise the template cache: a template added in a transaction
-- that then rolls back must not linger in other backends' caches.
CREATE TRIGGER postal_code_templates_changed
   AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON postal_code_templates
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
