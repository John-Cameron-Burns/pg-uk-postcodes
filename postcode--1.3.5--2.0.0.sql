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
SELECT pg_extension_config_dump('postal_code_formats', $$WHERE name LIKE 'template:%'$$);

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
      RAISE EXCEPTION 'unknown postal_code format %, must be one of: %',
         format_name, (SELECT string_agg(name, ', ' ORDER BY name) FROM postal_code_formats);
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
-- Slots 16..62 are available, the same template is only ever stored once,
-- and countries sharing a shape share a slot.
CREATE TABLE postal_code_templates (
   slot       smallint PRIMARY KEY CHECK (slot BETWEEN 16 AND 62),
   template   text NOT NULL UNIQUE,
   created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE postal_code_templates IS
   'The templated postal_code formats in use: the slot is the format tag stored in every value written under it, so rows are permanent -- they cannot be updated or deleted. Add them with add_country_template(), not by hand. Included in pg_dump, because values cannot be read without them.';
SELECT pg_extension_config_dump('postal_code_templates', '');

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
      SELECT min(g) INTO free_slot FROM generate_series(16, 62) g
      WHERE g NOT IN (SELECT t.slot FROM postal_code_templates t);
      IF free_slot IS NULL THEN
         RAISE EXCEPTION 'all 47 postal_code template slots are in use';
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
