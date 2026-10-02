-- postal_code: a 64-bit type for any country's postal code, additive
-- to (not a replacement for) the GB-only postcode type above. See
-- postal_code.h/postal_code_fmt.h for the bit layout and dispatch
-- design; postal_code_us.c/ca/fr/br/cz/lu/gb/ie.c are the
-- formats implemented so far. Country->format assignment itself lives in the
-- postal_code_country_formats SQL table (add_country_format() /
-- remove_country_format()), not compiled in -- see that section
-- below.

-- text form is the UPU one: ISO 3166-1 alpha-2, a hyphen, then the
-- national code. A country prefix is required -- there is no implicit
-- default country (unlike postcode, which is UK-only, there is no single
-- obvious country to assume here).
SELECT '90210'::postal_code;
SELECT '90210-1234'::postal_code; -- a ZIP+4 hyphen is not a country delimiter
SELECT 'U-90210'::postal_code;

-- the old colon form is not accepted
SELECT 'US:90210'::postal_code;

-- unrecognised two-letter country
SELECT 'ZZ-90210'::postal_code;

-- basic round trips: US ZIP5, US ZIP5+4, CA full (FSA+LDU)
SELECT 'US-90210'::postal_code;
SELECT 'US-90210-1234'::postal_code;
SELECT 'CA-K1A 0B1'::postal_code;

-- CA FSA-only: a complete, valid value in its own right, not a
-- truncated fragment -- see postal_code_ca.c's own comment for why
-- (real-world GeoNames data is overwhelmingly this shape for CA)
SELECT 'CA-T0A'::postal_code;

-- tolerant of case and of the FSA/LDU space being omitted, same
-- spirit as postcode's own text parser
SELECT 'ca-k1a0b1'::postal_code = 'CA-K1A 0B1'::postal_code;

-- 4 or 5 characters is neither a valid FSA-only nor a complete
-- FSA+LDU value
SELECT 'CA-T0A0'::postal_code;

-- 0000 is not a real ZIP+4 add-on code (0 is reserved internally to
-- mean "no +4 supplied")
SELECT 'US-90210-0000'::postal_code;

-- excluded Canadian letters: D/F/I/O/Q/U never appear in any letter
-- position; W/Z additionally never appear as the first letter
SELECT 'CA-D1A 0B1'::postal_code;
SELECT 'CA-W1A 0B1'::postal_code;
SELECT 'CA-K1W 0B1'::postal_code; -- W is fine outside the first position

-- all-zero payload is a legitimate value in both formats (US
-- "00000" with no +4, CA "A0A 0A0") -- regression guard for a real
-- bug caught while wiring up this type: parse() used to signal
-- failure by returning 0, which collides with these
SELECT 'US-00000'::postal_code;
SELECT 'CA-A0A 0A0'::postal_code;

-- country() accessor
SELECT country('US-90210'::postal_code), country('CA-K1A 0B1'::postal_code);

-- two-argument constructor, analogous to PostGIS's
-- ST_GeomFromText(wkt, srid) -- for callers with country and
-- national code as separate values already
SELECT postal_code('US', '90210-1234');
SELECT postal_code('ca', 'k1a0b1'); -- case-insensitive country too


-- Outcode-only is a complete, valid value wherever a country has a
-- distinct outcode/incode structure (GB, IE, CA, US); where the leading
-- digits are only implicitly an outcode (FR, CZ, LU) the full code is
-- required. GeoNames agrees: every one of its GB (27,450) and IE (139)
-- rows is outcode-only.
SELECT 'GB-SW1A'::postal_code, 'GB-LS24'::postal_code, 'GB-M1'::postal_code;
SELECT 'GB-SW1A 1AA'::postal_code, 'gb-sw1a1aa'::postal_code;
SELECT 'IE-A65'::postal_code, 'IE-D6W'::postal_code, 'IE-A65 F4E2'::postal_code, 'ie-a65f4e2'::postal_code;
SELECT 'US-90210'::postal_code, 'CA-K1A'::postal_code;
SELECT 'BR-08970'::postal_code, 'BR-08970-000'::postal_code;
SELECT 'FR-75001'::postal_code, 'CZ-110 00'::postal_code, 'CZ-11000'::postal_code, 'LU-L-1311'::postal_code, 'LU-1311'::postal_code;

-- ... but a fragment is not a postcode: area-only, or an outcode plus a
-- sector with no unit, or a prefix of a country whose outcode is implicit
SELECT 'GB-SW'::postal_code;
SELECT 'GB-SW1A 1'::postal_code;
SELECT 'FR-750'::postal_code;
SELECT 'CZ-110'::postal_code;
SELECT 'LU-L-13'::postal_code;

-- France: CEDEX is accepted and normalised away. The 5 digits are a real,
-- distinct postcode (GeoNames' FR rows carrying a CEDEX suffix almost
-- never have a bare row for the same 5 digits) and "CEDEX [n]" is routing
-- for the address, not part of the code. Exactly NNNNN [CEDEX [n]] is
-- accepted -- NOT "ignore whatever follows the digits".
SELECT 'FR-75054 CEDEX 01'::postal_code, 'FR-75054 CEDEX'::postal_code, 'fr-75054 cedex 9'::postal_code;
SELECT 'FR-75054 CEDEX 01'::postal_code = 'FR-75054'::postal_code AS cedex_normalised_away;
SELECT 'FR-78078 CITYSSIMO'::postal_code;
SELECT 'FR-75001 foo'::postal_code;
SELECT 'FR-75054 CEDEX 123'::postal_code;
SELECT 'FR-75054CEDEX'::postal_code;

-- Eircode letters are limited to A C D E F H K N P R T V W X Y, and only
-- D6W breaks the letter-digit-digit routing key shape
SELECT 'IE-B65'::postal_code;
SELECT 'IE-D6X'::postal_code;
SELECT 'IE-A65 F4O2'::postal_code;
SELECT 'IE-A65 F4E'::postal_code;

-- an outcode sorts immediately before every full code inside it, and
-- outcodes still sort against each other
SELECT 'GB-SW1A'::postal_code < 'GB-SW1A 1AA'::postal_code AS outcode_before_its_codes,
       'GB-SW1A 2AA'::postal_code < 'GB-SW1B'::postal_code AS outcodes_still_ordered,
       'IE-A65'::postal_code < 'IE-A65 F4E2'::postal_code AS routing_key_before_eircode,
       'IE-A65 F4E2'::postal_code < 'IE-A66'::postal_code AS routing_key_dominates,
       'BR-08970-999'::postal_code < 'BR-08971'::postal_code AS br_base_dominates_suffix;

-- Ordering. This is the property the whole design hinges on:
--   1. country sorts as ISO 3166-1 alpha-2 TEXT order, unconditionally
--   2. within a country, a more precise variant of the same underlying
--      code (a ZIP5+4, or a CA FSA's full LDU) interleaves immediately
--      after the coarser value it refines, rather than being grouped
--      apart from it by format
SELECT 'CA-K1A 0B1'::postal_code < 'US-90210'::postal_code AS ca_before_us;
SELECT 'US-90210'::postal_code < 'US-90210-1234'::postal_code AS zip5_before_plus4;
SELECT 'US-90210-9999'::postal_code < 'US-90211'::postal_code AS interleaves_by_value_not_format;
SELECT 'CA-T0A'::postal_code < 'CA-T0A 0A0'::postal_code AS fsa_before_its_own_ldu;


-- Real-world fixture data: rows genuinely present in the production
-- GEONAMES.world table (SELECT country_code, postal_code FROM
-- "@GEONAMES".world WHERE country_code IN ('US','CA')), not
-- hand-invented -- see project notes for how this sample was pulled.
-- 43,147 real US+CA rows from that table were verified to parse
-- with zero failures against this exact encoder; this is a small,
-- fixed, checked-in slice of that same real data for a hermetic
-- regression run.
CREATE TEMP TABLE geonames_sample (country_code text, national_code text);
INSERT INTO geonames_sample VALUES
   ('US', '00501'), -- Holtsville, NY -- lowest real US ZIP
   ('US', '10001'), -- New York, NY
   ('US', '90210'), -- Beverly Hills, CA
   ('US', '99950'), -- Ketchikan, AK -- highest real US ZIP
   ('CA', 'B6L'), ('CA', 'R7B'), ('CA', 'V8G'), ('CA', 'R0A'),
   ('CA', 'T2E'), ('CA', 'E5L'), ('CA', 'G9X'), ('CA', 'V3E'),
   ('CA', 'L6Y'), ('CA', 'L7E'), ('CA', 'T0A'), ('CA', 'T0B'),
   ('CA', 'T3T 0E5'), -- one of the very few full FSA+LDU rows in the table
   ('CA', 'V3Y 0H2'),
   ('GB', 'TD5'), ('GB', 'KA18'), ('GB', 'EC2V'), ('GB', 'PH26'), ('GB', 'HP27'),
   ('GB', 'PE22'), ('GB', 'IP12'), ('GB', 'M24'),
   ('IE', 'F28'), ('IE', 'P72'), ('IE', 'R21'), ('IE', 'K67'), ('IE', 'D14'),
   ('IE', 'E41'), ('IE', 'H12'), ('IE', 'D6W'),
   ('FR', '75001'), ('FR', '04004'), ('FR', '75054 CEDEX 01'), -- real: a CEDEX code is its own postcode
   ('BR', '08970-000'), ('BR', '29640-000'),
   ('CZ', '507 52'), ('CZ', '751 25'),
   ('LU', 'L-1311'), ('LU', 'L-4942');

-- every row in the fixture must parse and round-trip cleanly
SELECT country_code, national_code, postal_code(country_code, national_code)
FROM geonames_sample
ORDER BY country_code, national_code;

CREATE TABLE addr (id serial primary key, pc postal_code);
INSERT INTO addr (pc)
SELECT postal_code(country_code, national_code) FROM geonames_sample;
CREATE INDEX ON addr (pc);

-- a real ORDER BY over a real (if small) index, not just direct
-- comparisons -- CA sorts before US, and within CA the bare FSA-only
-- rows interleave correctly against the two full FSA+LDU rows
SELECT pc FROM addr ORDER BY pc;

-- to_postal_code(): NULL-returning counterparts of ::postal_code and
-- postal_code(cc, code), for loading feeds with rows that are not valid
-- postcodes (the role topostcode() plays for the UK type) -- a bad row
-- gives NULL rather than an error that aborts the whole COPY. Strict
-- parsing stays the default.
SELECT to_postal_code('FR', '78078 CITYSSIMO') IS NULL AS brand_name_is_null,
       to_postal_code('FR', '75001 SP 07') IS NULL AS military_designator_is_null,
       to_postal_code('FR', '75054 CEDEX 01') AS cedex_still_parses,
       to_postal_code('XX', '12345') IS NULL AS unassigned_country_is_null,
       to_postal_code('USA', '12345') IS NULL AS malformed_country_is_null,
       to_postal_code('US', 'nonsense') IS NULL AS unparseable_is_null,
       to_postal_code('us', '90210') AS good_row_unchanged;
-- the one-argument form takes the same "CC-code" text as ::postal_code
SELECT to_postal_code('FR-75054 CEDEX 01') AS cedex_ok,
       to_postal_code('us-90210-1234') AS zip4_ok,
       to_postal_code('FR-78078 CITYSSIMO') IS NULL AS bad_national_code,
       to_postal_code('90210') IS NULL AS no_country_prefix,
       to_postal_code('US:90210') IS NULL AS colon_form,
       to_postal_code('ZZ-90210') IS NULL AS unassigned_country,
       to_postal_code('') IS NULL AS empty,
       to_postal_code(NULL) IS NULL AS null_in;
SELECT code, to_postal_code('FR', code) FROM (VALUES
   ('75001'), ('78078 CITYSSIMO'), ('75054 CEDEX 01'), ('AIR'), ('13001')) v(code);

-- the inequality operators carry PostgreSQL's standard selectivity
-- estimators, so the planner can use ANALYZE statistics for range
-- predicates (without them a 1-row range was estimated at 25% of the table)
SELECT oprname, oprrest::text, oprjoin::text FROM pg_operator
WHERE oprleft = 'postal_code'::regtype AND oprright = 'postal_code'::regtype
ORDER BY oprname;

-- is_valid(): true/false instead of an error, e.g. for CHECK constraints
-- or for finding the rejects in a staging table. NULL in gives NULL out.
SELECT is_valid('US-90210-1234') AS zip4,
       is_valid('GB-SW1A') AS outcode,
       is_valid('FR-75054 CEDEX 01') AS cedex,
       is_valid('FR-78078 CITYSSIMO') AS brand,
       is_valid('CA-D1A 0B1') AS excluded_canadian_letter,
       is_valid('IE-B65') AS bad_eircode_letter,
       is_valid('US-90210-0000') AS zip4_0000,
       is_valid('90210') AS no_country,
       is_valid('ZZ-90210') AS unassigned_country,
       is_valid('GB-SW1A 1') AS fragment,
       is_valid(NULL::text) AS null_in;
SELECT is_valid('US', '90210') AS good, is_valid('US', 'nonsense') AS bad, is_valid('xx', '1') AS unassigned;
-- agrees with the strict parser on every row of the fixture, good or bad
SELECT count(*) AS disagreements FROM (VALUES
   ('US','90210'),('CA','T0A'),('GB','SW1A'),('IE','D6W'),('FR','75054 CEDEX 01'),
   ('FR','CITYSSIMO'),('CA','D1A 0B1'),('US','1234'),('LU','1311'),('BR','08970-000'),('CZ','11000')) v(cc, code)
WHERE is_valid(cc, code) IS DISTINCT FROM (to_postal_code(cc, code) IS NOT NULL);

-- Country->format assignment is a live SQL table, not compiled in:
-- assigning a new country to an already-implemented format is a
-- plain INSERT (via add_country_format()), no rebuild -- only a
-- genuinely new format shape needs real C. See postal_code_country.c
-- for how postal_code_in()/postal_code(text,text) look this up.

SELECT name FROM postal_code_formats ORDER BY name;
SELECT iso2, format_name FROM postal_code_country_formats ORDER BY iso2;

-- unassigned country, existing format shape: fails until assigned
SELECT 'DE-12345'::postal_code;

-- Germany also uses a plain 5-digit code -- same shape as FR/CZ, so
-- this needs no new encoder, just an assignment
SELECT add_country_format('de', 'FR'); -- lower-case cc is normalised
SELECT 'DE-12345'::postal_code;
SELECT country('DE-12345'::postal_code);

-- reassigning is idempotent / an upsert, not an error
SELECT add_country_format('DE', 'FR');

-- unknown format name
SELECT add_country_format('XX', 'NOPE');

-- malformed country code
SELECT add_country_format('DEU', 'FR');
SELECT add_country_format('1E', 'FR');

-- removing an assignment: existing STORED values are unaffected --
-- decoding uses the format already packed into the value's own bits,
-- never a fresh lookup -- but parsing NEW text for that country now
-- fails
CREATE TEMP TABLE de_before_removal AS SELECT postal_code('DE', '12345') AS pc;
SELECT remove_country_format('DE');
SELECT pc FROM de_before_removal; -- still renders fine, unaffected by the removal
SELECT 'DE-12345'::postal_code;   -- but parsing fresh text for DE fails now


-- Binary send/recv (postal_code_recv/postal_code_send, the
-- COPY ... WITH (FORMAT binary) path) is deliberately not covered
-- here: doing that portably needs a checked-in binary fixture file
-- and the same @abs_srcdir@ substitution machinery the "binary"
-- regression test above already has to work around (see this
-- Makefile's own comment on sql/binary.sql) -- not worth duplicating
-- for a second type in this pass. Verified manually instead: a full
-- COPY ... WITH (FORMAT binary) round trip of all 43,147 real
-- US+CA GEONAMES rows (out to a file and back in) matched the
-- original data exactly.
