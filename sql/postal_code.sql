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

-- postal_code(postcode, cc), analogous to PostGIS's ST_GeomFromText(wkt,
-- srid): for callers with the national code and the country as separate
-- values. The country may also come from the postcode's own "CC-" prefix.
SELECT postal_code('90210-1234', 'US');
SELECT postal_code('k1a0b1', 'ca'); -- case-insensitive country too

-- the country can come from cc, from the postcode's own prefix, or from both
-- (which must agree). A prefix is exactly two letters then a hyphen, which
-- no national format starts with (LU's 'L-1311' has one letter).
SELECT postal_code('90210-1234', 'US') AS from_cc,
       postal_code('US-90210-1234', NULL) AS from_prefix,
       postal_code('US-90210-1234', 'us') AS both_agree,
       postal_code('us-90210-1234', 'US') AS prefix_case_insensitive,
       postal_code('L-1311', 'LU') AS lu_national_code_is_not_a_prefix,
       postal_code('LU-L-1311', NULL) AS lu_prefixed,
       postal_code(NULL, 'US') IS NULL AS null_postcode_is_null;
SELECT postal_code('US-90210', 'CA');   -- cc and prefix disagree
SELECT postal_code('90210', NULL);      -- no country anywhere
SELECT postal_code('90210', 'USA');     -- malformed country
SELECT postal_code('U-90210', NULL);    -- not a prefix, so no country
SELECT postal_code('US-', NULL);        -- a prefix with nothing after it


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
SELECT country_code, national_code, postal_code(national_code, country_code)
FROM geonames_sample
ORDER BY country_code, national_code;

CREATE TABLE addr (id serial primary key, pc postal_code);
INSERT INTO addr (pc)
SELECT postal_code(national_code, country_code) FROM geonames_sample;
CREATE INDEX ON addr (pc);

-- a real ORDER BY over a real (if small) index, not just direct
-- comparisons -- CA sorts before US, and within CA the bare FSA-only
-- rows interleave correctly against the two full FSA+LDU rows
SELECT pc FROM addr ORDER BY pc;

-- to_postal_code(): NULL-returning counterparts of ::postal_code and
-- postal_code(postcode, cc), for loading feeds with rows that are not valid
-- postcodes (the role topostcode() plays for the UK type) -- a bad row
-- gives NULL rather than an error that aborts the whole COPY. Strict
-- parsing stays the default.
SELECT to_postal_code('78078 CITYSSIMO', 'FR') IS NULL AS brand_name_is_null,
       to_postal_code('75001 SP 07', 'FR') IS NULL AS military_designator_is_null,
       to_postal_code('75054 CEDEX 01', 'FR') AS cedex_still_parses,
       to_postal_code('12345', 'XX') IS NULL AS unassigned_country_is_null,
       to_postal_code('12345', 'USA') IS NULL AS malformed_country_is_null,
       to_postal_code('nonsense', 'US') IS NULL AS unparseable_is_null,
       to_postal_code('90210', 'us') AS good_row_unchanged;
-- the one-argument form takes the same "CC-code" text as ::postal_code
SELECT to_postal_code('FR-75054 CEDEX 01') AS cedex_ok,
       to_postal_code('us-90210-1234') AS zip4_ok,
       to_postal_code('FR-78078 CITYSSIMO') IS NULL AS bad_national_code,
       to_postal_code('90210') IS NULL AS no_country_prefix,
       to_postal_code('US:90210') IS NULL AS colon_form,
       to_postal_code('ZZ-90210') IS NULL AS unassigned_country,
       to_postal_code('') IS NULL AS empty,
       to_postal_code(NULL) IS NULL AS null_in;
-- the same prefix/cc rules: whatever would raise in the strict form is NULL here
SELECT to_postal_code('US-90210', 'CA') IS NULL AS mismatch_is_null,
       to_postal_code('90210', NULL) IS NULL AS no_country_is_null,
       to_postal_code('US-90210', NULL) AS prefix_only,
       to_postal_code('90210', 'US') AS cc_only,
       to_postal_code('US-90210', 'us') AS both_agree;
SELECT code, to_postal_code(code, 'FR') FROM (VALUES
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
SELECT is_valid('90210', 'US') AS good, is_valid('nonsense', 'US') AS bad, is_valid('1', 'xx') AS unassigned;
SELECT is_valid('US-90210', 'CA') AS mismatch, is_valid('90210', NULL) AS no_country,
       is_valid('US-90210', NULL) AS prefix_only, is_valid('US-90210', 'US') AS both_agree,
       is_valid(NULL, 'US') AS null_postcode;
-- agrees with the strict parser on every row of the fixture, good or bad
SELECT count(*) AS disagreements FROM (VALUES
   ('US','90210'),('CA','T0A'),('GB','SW1A'),('IE','D6W'),('FR','75054 CEDEX 01'),
   ('FR','CITYSSIMO'),('CA','D1A 0B1'),('US','1234'),('LU','1311'),('BR','08970-000'),('CZ','11000')) v(cc, code)
WHERE is_valid(code, cc) IS DISTINCT FROM (to_postal_code(code, cc) IS NOT NULL);

-- Country->format assignment is a live SQL table, not compiled in:
-- assigning a new country to an already-implemented format is a
-- plain INSERT (via add_country_format()), no rebuild -- only a
-- genuinely new format shape needs real C. See postal_code_country.c
-- for how postal_code_in()/postal_code(text,text) look this up.

SELECT name FROM postal_code_formats WHERE name NOT LIKE 'template:%' ORDER BY name;
SELECT iso2, format_name FROM postal_code_country_formats
WHERE iso2 IN ('BR', 'CA', 'CZ', 'FR', 'LU', 'US', 'GB', 'GG', 'IM', 'JE', 'IE') ORDER BY iso2;

-- unassigned country, existing format shape: fails until assigned
SELECT 'XZ-12345'::postal_code;

-- another country uses a plain 5-digit code -- same shape as FR/CZ, so
-- this needs no new encoder, just an assignment
SELECT add_country_format('xz', 'FR'); -- lower-case cc is normalised
SELECT 'XZ-12345'::postal_code;
SELECT country('XZ-12345'::postal_code);

-- reassigning is idempotent / an upsert, not an error
SELECT add_country_format('XZ', 'FR');

-- unknown format name
SELECT add_country_format('XX', 'NOPE');

-- malformed country code
SELECT add_country_format('DEU', 'FR');
SELECT add_country_format('1E', 'FR');

-- removing an assignment: existing STORED values are unaffected --
-- decoding uses the format already packed into the value's own bits,
-- never a fresh lookup -- but parsing NEW text for that country now
-- fails
CREATE TEMP TABLE xz_before_removal AS SELECT postal_code('12345', 'XZ') AS pc;
SELECT remove_country_format('XZ');
SELECT pc FROM xz_before_removal; -- still renders fine, unaffected by the removal
SELECT 'XZ-12345'::postal_code;   -- but parsing fresh text for XZ fails now


-- ===== Partial match: fragments, bounds and ranges ============================
-- A fragment is "CC-" plus a PREFIX of the national code. Each format orders
-- its values exactly as its text sorts, so a prefix is one contiguous range
-- [lower_bound, upper_bound), and neighbouring prefixes tile. A fragment is
-- not a value: 'FR-75' is a fragment but not a postcode.

SELECT lower_bound('FR-75') AS lo, upper_bound('FR-75') AS hi;       -- 2 of 5 digits
SELECT lower_bound('FR-750') AS lo, upper_bound('FR-750') AS hi;     -- 3 of 5
SELECT lower_bound('US-90210') AS lo, upper_bound('US-90210') AS hi; -- a bare ZIP5 covers its +4s too
SELECT lower_bound('US-90210-1') AS lo, upper_bound('US-90210-1') AS hi;
SELECT lower_bound('US-90210-9999') AS lo, upper_bound('US-90210-9999') AS hi; -- last add-on ends at the next ZIP5
SELECT lower_bound('BR-08970-0') AS lo, upper_bound('BR-08970-0') AS hi;
SELECT lower_bound('CA-K') AS lo, upper_bound('CA-K') AS hi;         -- the smallest VALID value: an outcode
SELECT lower_bound('CA-V') AS lo, upper_bound('CA-V') AS hi;         -- W is never a first letter
SELECT lower_bound('CA-K1C') AS lo, upper_bound('CA-K1C') AS hi;     -- D is never used
SELECT lower_bound('CA-K1A 9') AS lo, upper_bound('CA-K1A 9') AS hi; -- carries out of the LDU to the next FSA
SELECT lower_bound('IE-A99') AS lo, upper_bound('IE-A99') AS hi;     -- there is no B
SELECT lower_bound('IE-D69') AS lo, upper_bound('IE-D69') AS hi;     -- ... and D6W sits between D69 and D70
SELECT lower_bound('IE-D6W') AS lo, upper_bound('IE-D6W') AS hi;
SELECT lower_bound('GB-LS1') AS lo, upper_bound('GB-LS1') AS hi;     -- district LS1 only, not LS1x
SELECT lower_bound('GB-LS19') AS lo, upper_bound('GB-LS19') AS hi;
SELECT lower_bound('GB-SW1A 1') AS lo, upper_bound('GB-SW1A 1') AS hi;
SELECT lower_bound('GB-ZE') AS lo, upper_bound('GB-ZE') AS hi;       -- area list is append-only: GX follows ZE

-- the top of a country has no successor value, so the upper bound is that
-- country's end-of-country bound 'XX-~': after every real value of the country
-- and before the next. It is a bound, never a postcode.
SELECT lower_bound('US-99') AS lo, upper_bound('US-99') AS hi;
SELECT lower_bound('CA-Y') AS lo, upper_bound('CA-Y') AS hi;
SELECT lower_bound('GB-GX') AS lo, upper_bound('GB-GX') AS hi;
SELECT lower_bound('IE-Y') AS lo, upper_bound('IE-Y') AS hi;
SELECT 'US-99999'::postal_code < 'US-~'::postal_code AS after_the_last_us_code,
       'US-~'::postal_code < 'ZA-~'::postal_code AS before_the_next_country,
       'US-~'::postal_code > 'US-99999-9999'::postal_code AS after_the_last_us_plus4,
       country('US-~'::postal_code) AS still_knows_its_country;
-- ... but it is not a postcode: nothing validates, parses or constructs it
SELECT is_valid('US-~') AS is_valid, to_postal_code('US-~') IS NULL AS to_postal_code_is_null;
SELECT postal_code('~', 'US');
SELECT 'US-'::postal_code;
SELECT 'U1-~'::postal_code;

-- postal_prefix(): the range itself, a native PostgreSQL range type
SELECT postal_prefix('GB-LS24');
SELECT postal_prefix('US-99');          -- ends at the end-of-country bound
SELECT postal_prefix('CA-K1C');
SELECT postal_prefix('IE-D6');
SELECT postal_prefix('FR-75') @> 'FR-75054'::postal_code AS contains,
       postal_prefix('FR-75') @> 'FR-76000'::postal_code AS next_prefix_excluded,
       'US-99999'::postal_code <@ postal_prefix('US-99') AS top_of_country_included;
-- the top of one country must not run on into the next ones: BR sorts before CA
SELECT 'CA-K1A'::postal_code <@ postal_prefix('BR-99') AS later_country_excluded,
       'BR-99999-999'::postal_code <@ postal_prefix('BR-99') AS own_top_included;

-- neighbouring prefixes are adjacent: no gap and no overlap
SELECT postal_prefix('CA-K1C') -|- postal_prefix('CA-K1E') AS skips_the_unused_D,
       postal_prefix('GB-LS19') -|- postal_prefix('GB-LS1A') AS digits_then_letters,
       postal_prefix('IE-D69') -|- postal_prefix('IE-D6W') AS d69_d6w,
       postal_prefix('IE-D6W') -|- postal_prefix('IE-D70') AS d6w_d70,
       postal_prefix('US-90210') -|- postal_prefix('US-90211') AS zips,
       postal_prefix('BR-08970') -|- postal_prefix('BR-08971') AS ceps;

-- things that are not fragments
SELECT postal_prefix('FR-75A');
SELECT postal_prefix('FR-75001 CEDEX');
SELECT postal_prefix('CA-D');
SELECT postal_prefix('IE-B');
SELECT postal_prefix('US-90210-0000');
SELECT postal_prefix('75');
SELECT postal_prefix('ZZ-1');

-- on the real-data fixture: a range matches exactly the values whose text
-- starts with the fragment (fragments chosen where GB's hierarchical rule
-- and plain text prefix agree)
SELECT f.frag, count(*) FILTER (WHERE a.pc <@ postal_prefix(f.frag)) AS matches,
       count(*) FILTER (WHERE (a.pc <@ postal_prefix(f.frag)) IS DISTINCT FROM (a.pc::text LIKE f.frag || '%')) AS disagreements
FROM addr a, (VALUES ('US-9'),('US-99'),('CA-T'),('CA-T0'),('CA-V'),('GB-PH'),('IE-D'),('FR-7'),
                     ('BR-0'),('BR-08970'),('CZ-5'),('LU-L-4')) f(frag)
GROUP BY f.frag ORDER BY f.frag;

-- a prefix search uses the index. A call with a constant fragment is folded
-- into a constant range at plan time so PostgreSQL's own rewrite of
-- "col <@ constant range" into btree conditions applies, the top of a country
-- included. (Helper reports whether the plan has an index
-- condition, which is stable output where the plan text itself is not.)
CREATE FUNCTION pg_temp.uses_index_cond(q text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE line text;
BEGIN
   FOR line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || q LOOP
      IF line LIKE '%Index Cond:%' THEN RETURN true; END IF;
   END LOOP;
   RETURN false;
END $$;
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT pg_temp.uses_index_cond($q$ SELECT * FROM addr WHERE pc <@ postal_prefix('GB-PH') $q$) AS bounded,
       pg_temp.uses_index_cond($q$ SELECT * FROM addr WHERE pc <@ postal_prefix('US-99') $q$) AS unbounded_top,
       pg_temp.uses_index_cond($q$ SELECT * FROM addr WHERE pc <@ postal_prefix('CA-K1C') $q$) AS skipping_unused_letter;
RESET enable_seqscan;
RESET enable_bitmapscan;

-- a fragment that is not a constant still works (computed per row; no folding)
SELECT count(*) AS joined FROM (VALUES ('US-9'), ('CA-T')) f(frag) JOIN addr a ON a.pc <@ postal_prefix(f.frag);

-- ===== The % operator =======================================================
-- pc % 'fragment': does pc start with the fragment? The UK type's operator,
-- ported. Same meaning as pc <@ postal_prefix(fragment), with its leniency: a
-- fragment that isn't one matches nothing (and !% matches everything), since
-- it is meant for arbitrary input such as a search box.
SELECT 'GB-LS24 9JT'::postal_code % 'GB-LS24' AS inside,
       'GB-LS25 9JT'::postal_code % 'GB-LS24' AS next_district,
       'GB-LS24 9JT'::postal_code % 'GB-LS2'  AS ls2_is_district_ls2_only,
       'US-90210-1234'::postal_code % 'US-902' AS zip_prefix,
       'US-90210-1234'::postal_code % 'US-90211' AS other_zip,
       'CA-K1A 0B1'::postal_code % 'CA-K1' AS ca,
       'IE-D6W'::postal_code % 'IE-D6' AS d6w_is_in_d6,
       'FR-75054'::postal_code % 'FR-75' AS fr_in,
       'FR-75054'::postal_code % 'FR-76' AS fr_out;
SELECT 'US-90210'::postal_code !% 'US-902' AS not_matching_is_false, 'US-90210'::postal_code !% 'US-903' AS not_matching_is_true;

-- a bad fragment is "no match", not an error
SELECT 'US-90210'::postal_code % 'nonsense' AS garbage,
       'US-90210'::postal_code % '90210' AS no_country,
       'US-90210'::postal_code % 'ZZ-1' AS unassigned_country,
       'US-90210'::postal_code % 'US-9x' AS not_a_prefix,
       'US-90210'::postal_code !% 'nonsense' AS negator_matches_everything,
       'US-90210'::postal_code % NULL AS null_fragment;

-- identical to the range form for every valid fragment, on the fixture
-- (fragments where GB's hierarchical rule and plain text prefix agree)
SELECT count(*) AS disagreements FROM addr a,
   (VALUES ('US-9'),('US-99'),('US-90210'),('CA-T'),('CA-T0'),('CA-V'),('GB-PH'),('IE-D'),('FR-7'),
           ('BR-0'),('BR-08970'),('CZ-5'),('LU-L-4'),('GB-GX'),('CA-Y')) f(frag)
WHERE (a.pc % f.frag) IS DISTINCT FROM (a.pc <@ postal_prefix(f.frag));

-- uses a btree index for a constant fragment, the top of a country included
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT pg_temp.uses_index_cond($q$ SELECT * FROM addr WHERE pc % 'GB-PH' $q$) AS bounded,
       pg_temp.uses_index_cond($q$ SELECT * FROM addr WHERE pc % 'US-99' $q$) AS top_of_country,
       pg_temp.uses_index_cond($q$ SELECT * FROM addr WHERE pc % 'nonsense' $q$) AS bad_fragment_is_left_alone;
RESET enable_seqscan;
RESET enable_bitmapscan;

-- a column fragment works too (computed per row)
SELECT count(*) AS joined FROM (VALUES ('US-9'), ('CA-T'), ('bad')) f(frag) JOIN addr a ON a.pc % f.frag;

-- the cached-plan safety net, for % as for postal_prefix(): Country XY is
-- assigned the plain-5-digit format, a row is stored, a statement is prepared
-- (its plan cached), then Country XY is reassigned to the Czech format. The
-- same prepared statement must now mean the CZ range.
SELECT add_country_format('XY', 'FR');
INSERT INTO addr (pc) VALUES ('XY-12345');
PREPARE xy_prefix AS SELECT pc FROM addr WHERE pc % 'XY-12';
EXECUTE xy_prefix;
EXECUTE xy_prefix;
SELECT add_country_format('XY', 'CZ');
INSERT INTO addr (pc) VALUES ('XY-12345');
EXECUTE xy_prefix;
DEALLOCATE xy_prefix;
SELECT remove_country_format('XY');
DELETE FROM addr WHERE pc::text LIKE 'XY-%';

-- ===== Locking a column to a country =======================================
-- postal_code('US') as a column type, the way PostGIS locks a geometry column
-- to an SRID with geometry(Point, 4326): the type modifier is the country.
SELECT format_type('postal_code'::regtype, 658) AS typmod_658_is,
       format_type('postal_code'::regtype, -1) AS unlocked;

CREATE TEMP TABLE us_only (id serial PRIMARY KEY, pc postal_code('US'));
CREATE TEMP TABLE anywhere (id serial PRIMARY KEY, pc postal_code);

-- a prefix is accepted (any case) if it agrees with the column's country
INSERT INTO us_only (pc) VALUES ('US-90210'), ('us-90210-1234'), ('US-10001'), ('us-99950'), ('US-~');
SELECT id, pc FROM us_only ORDER BY id;

-- ... and a different country is refused, however it is written
INSERT INTO us_only (pc) VALUES ('CA-K1A 0B1');
INSERT INTO us_only (pc) VALUES ('GB-SW1A');
INSERT INTO us_only (pc) VALUES ('CA-~');
INSERT INTO us_only (pc) VALUES ('nonsense');
INSERT INTO us_only (pc) VALUES ('US-');

-- PostgreSQL hands a string literal to the input function without the column's
-- type modifier (it applies the modifier afterwards), so in INSERT/UPDATE the
-- prefix is always needed, locked column or not; only COPY can omit it (below)
INSERT INTO us_only (pc) VALUES ('90210');
INSERT INTO anywhere (pc) VALUES ('90210');
INSERT INTO anywhere (pc) VALUES ('US-90210'), ('CA-K1A 0B1'), ('GB-SW1A');

-- values built by functions are checked when they are assigned
INSERT INTO us_only (pc) SELECT postal_code('90210-5678', 'US');
INSERT INTO us_only (pc) SELECT postal_code('SW1A', 'GB');
UPDATE us_only SET pc = 'CA-K1A 0B1' WHERE id = 1;
UPDATE us_only SET pc = 'US-10002' WHERE id = 3;
SELECT id, pc FROM us_only ORDER BY id;

-- the cast form, and ALTER COLUMN ... TYPE (which fails if any existing value
-- is from another country, and succeeds once they are gone)
SELECT 'US-90210'::postal_code('US') AS ok;
SELECT 'CA-K1A 0B1'::postal_code('US');
SELECT 'CA-K1A 0B1'::postal_code::postal_code('US');
ALTER TABLE anywhere ALTER COLUMN pc TYPE postal_code('US');
DELETE FROM anywhere WHERE pc <> 'US-90210';
ALTER TABLE anywhere ALTER COLUMN pc TYPE postal_code('US');
SELECT pc FROM anywhere;

-- COPY does pass the modifier to the input function, so a bulk load into a
-- locked column can use bare national codes
COPY us_only (pc) FROM stdin;
10003
US-10004
\.
COPY us_only (pc) FROM stdin;
10005
CA-K1A 0B1
\.
SELECT pc FROM us_only ORDER BY id DESC LIMIT 3;

-- a locked column is an ordinary postal_code column to everything else
CREATE INDEX ON us_only (pc);
SELECT count(*) AS zips_starting_9 FROM us_only WHERE pc % 'US-9';
SELECT count(*) AS in_range FROM us_only WHERE pc <@ postal_prefix('US-1000');
SELECT outcode(pc) AS outcode, country(pc) AS country FROM us_only WHERE id = 2;

-- what is locked to what
SELECT table_name, column_name, locked_to_country FROM postal_code_columns
WHERE table_name IN ('us_only', 'anywhere') ORDER BY table_name, column_name;

-- bad modifiers
CREATE TEMP TABLE bad1 (pc postal_code('USA'));
CREATE TEMP TABLE bad2 (pc postal_code('U1'));
CREATE TEMP TABLE bad3 (pc postal_code());
CREATE TEMP TABLE bad4 (pc postal_code('US', 'CA'));
CREATE TEMP TABLE lower_case_is_fine (pc postal_code('ca'));
SELECT format_type(atttypid, atttypmod) AS declared FROM pg_attribute
WHERE attrelid = 'lower_case_is_fine'::regclass AND attname = 'pc';

-- a lock to a country with nothing assigned is accepted (a column definition
-- has to survive a restore before the assignment data does) but nothing can
-- ever go into it
CREATE TEMP TABLE nowhere (pc postal_code('ZZ'));
INSERT INTO nowhere VALUES ('ZZ-12345');
SELECT is_valid('12345', 'ZZ') AS can_anything_be_valid_there;

-- ===== Templated formats =====================================================
-- A country made of fixed-width digit/letter groups needs only an SQL row.
--
-- First, a template that was rolled back must not be remembered. The first free slot is
-- NAN in the first transaction and ANA in the second, and the backend caches
-- what a slot means; the second must not see the first.
BEGIN;
SELECT add_country_template('XA', 'NAN');
SELECT 'XA-1A2'::postal_code;
ROLLBACK;
BEGIN;
SELECT add_country_template('XA', 'ANA');
SELECT 'XA-A1A'::postal_code;
SAVEPOINT s;
SELECT 'XA-1A2'::postal_code;
ROLLBACK TO s;
ROLLBACK;
SELECT 'XA-A1A'::postal_code;
SELECT count(*) AS user_templates_after_rollbacks FROM postal_code_templates WHERE NOT builtin;

-- templates that are not templates
SELECT postal_code_template_check('NNNNN[-NNNN]') AS ok, postal_code_template_check('X') AS also_ok;
SELECT postal_code_template_check('');
SELECT postal_code_template_check('nn');
SELECT postal_code_template_check('NN-');
SELECT postal_code_template_check('NN[N');
SELECT postal_code_template_check('NN[N][N]');
SELECT postal_code_template_check('XXXXXXXXXX');
\set VERBOSITY terse
SELECT add_country_template('XA', 'NN?');
SELECT add_country_template('PLX', 'NN');
\set VERBOSITY default

-- Assigning countries. These persist until the end of the section (the
-- templates themselves are permanent), so the checks below can fail freely.
SELECT add_country_template('XA', 'NN-NNN');
SELECT add_country_template('XB', 'NNNN AA');
SELECT add_country_template('XC', 'NNN NN');
SELECT add_country_template('XD', 'NNNNN[-NNNN]');
SELECT add_country_template('XE', 'NNNN');
SELECT add_country_template('XF', 'NNNN');      -- the same shape shares a slot
SELECT add_country_template('pl', 'NN-NNN');    -- cc is normalised; same template, same slot
SELECT template FROM postal_code_templates WHERE NOT builtin ORDER BY slot;
SELECT iso2, format_name FROM postal_code_country_formats WHERE iso2 BETWEEN 'XA' AND 'XF' ORDER BY iso2;

-- in, out, either case, separators optional
SELECT 'XA-00-950'::postal_code AS a, 'xa-00950'::postal_code AS b, postal_code('00-950', 'XA') AS c, postal_code('00950', 'XA') AS d;
SELECT 'XB-1012 jl'::postal_code AS a, 'XB-1012JL'::postal_code AS b;
SELECT 'XC-114 55'::postal_code, 'XD-98000'::postal_code AS bare, 'XD-98000-0001'::postal_code AS plus4;
SELECT 'XD-98000-0000'::postal_code AS zeros_are_fine_in_a_template;

-- bad input says why
SELECT 'XA-0O-950'::postal_code;
SELECT 'XA-00-9500'::postal_code;
SELECT 'XA-00-95'::postal_code;
SELECT 'XB-1012 J'::postal_code;
SELECT 'XB-1012 11'::postal_code;
SELECT 'XD-98000-'::postal_code;
SELECT to_postal_code('XA-00-9500') AS null_not_error, is_valid('XA-00-950') AS yes, is_valid('XA-00-95') AS no;

-- ordering is text ordering; a coarser value sorts before the finer ones, and
-- countries stay in ISO order whichever kind of format they use
SELECT pc FROM (VALUES ('XD-98000-0001'), ('XD-98000'), ('XD-97999-9999'), ('XD-98001'), ('XD-98000-0000'),
                       ('XB-1012 JL'), ('XB-1012 JA'), ('XB-1011 ZZ'), ('XD-~'), ('XA-00-950'), ('XA-00-949'),
                       ('GB-SW1A'), ('XE-1010'), ('US-90210')) v(t), LATERAL (SELECT t::postal_code AS pc) x
ORDER BY pc;

-- outcode: the part before the optional group, if the template has one
SELECT pc, outcode(pc) AS outcode, district(pc) AS district
FROM (VALUES ('XD-98000-0001'), ('XD-98000'), ('XA-00-950'), ('XB-1012 JL')) v(t), LATERAL (SELECT t::postal_code AS pc) x;
SELECT outcode(outcode('XD-98000-0001')) = outcode('XD-98000-0001') AS idempotent;

-- fragments, bounds and ranges, as for the compiled formats
SELECT lower_bound('XA-00') AS lo, upper_bound('XA-00') AS hi;
SELECT lower_bound('XA-00-9') AS lo, upper_bound('XA-00-9') AS hi;
SELECT lower_bound('XA-99') AS lo, upper_bound('XA-99') AS hi_is_the_end_of_the_country;
SELECT lower_bound('XB-10') AS lo, upper_bound('XB-10') AS hi;
SELECT lower_bound('XB-1012 J') AS lo, upper_bound('XB-1012 J') AS hi;
SELECT lower_bound('XB-1012 ZZ') AS lo, upper_bound('XB-1012 ZZ') AS hi;
SELECT lower_bound('XD-98000') AS lo, upper_bound('XD-98000') AS hi;
SELECT lower_bound('XD-98000-') AS lo, upper_bound('XD-98000-') AS hi;
SELECT lower_bound('XD-98000-12') AS lo, upper_bound('XD-98000-12') AS hi;
SELECT lower_bound('XD-98000-9999') AS lo, upper_bound('XD-98000-9999') AS hi;
SELECT lower_bound('XD-99999-99') AS lo, upper_bound('XD-99999-99') AS hi_is_the_end_of_the_country;
SELECT postal_prefix('XC-11') AS r, 'XC-114 55'::postal_code <@ postal_prefix('XC-11') AS inside;
SELECT lower_bound('XA-00-9500');
SELECT lower_bound('XA-A');
SELECT lower_bound('XB-1012 JLX');

-- partial match
SELECT 'XD-98000-0001'::postal_code % 'XD-98', 'XD-98000'::postal_code % 'XD-98000-', 'XD-97999'::postal_code % 'XD-98',
       'XB-1012 JL'::postal_code % 'XB-1012 J', 'XB-1012 JL'::postal_code !% 'XB-1013', 'XA-00-950'::postal_code % 'XA-0';

-- all of it over an index
CREATE TEMP TABLE zips (id serial, pc postal_code);
INSERT INTO zips (pc) SELECT postal_code(lpad(g::text, 5, '0'), 'XD') FROM generate_series(95000, 99999, 7) g;
INSERT INTO zips (pc) SELECT postal_code(lpad((95000 + g)::text, 5, '0') || '-' || lpad(g::text, 4, '0'), 'XD') FROM generate_series(1, 4000, 13) g;
CREATE INDEX ON zips (pc);
ANALYZE zips;
SELECT count(*) AS by_range FROM zips WHERE pc <@ postal_prefix('XD-9812');
SELECT count(*) AS by_text  FROM zips WHERE pc::text LIKE 'XD-9812%';
SELECT count(*) AS by_op    FROM zips WHERE pc % 'XD-9812';
SELECT count(*) AS plus4s   FROM zips WHERE pc % 'XD-96000-0';
SELECT count(*) AS by_text  FROM zips WHERE pc::text LIKE 'XD-96000-0%';
SET enable_seqscan = off;
EXPLAIN (COSTS OFF) SELECT * FROM zips WHERE pc <@ postal_prefix('XD-9812');
RESET enable_seqscan;

-- a column locked to a templated country
CREATE TEMP TABLE pl (pc postal_code('XA'));
INSERT INTO pl VALUES ('XA-00-950');
COPY pl FROM stdin;
01-001
\.
INSERT INTO pl VALUES ('XB-1012 JL');
SELECT pc FROM pl ORDER BY pc;

-- a country moves to a different template: new values follow the new one, values
-- already stored go on reading as they were written
CREATE TEMP TABLE pl_old AS SELECT 'XA-00-950'::postal_code AS pc;
SELECT add_country_template('XA', 'NNNNN');
SELECT 'XA-00950'::postal_code AS new_style;
SELECT 'XA-00-950'::postal_code;
SELECT pc AS still_reads_as_written, outcode(pc) IS NULL AS no_outcode FROM pl_old;
SELECT pc = 'XA-00950'::postal_code AS different_format_different_value FROM pl_old;
SELECT template FROM postal_code_templates WHERE NOT builtin ORDER BY slot;

-- a template is permanent once written: values are read back through it
\set VERBOSITY terse
UPDATE postal_code_templates SET template = 'NNNNN' WHERE slot = 12;
DELETE FROM postal_code_templates WHERE slot = 12;
TRUNCATE postal_code_templates;
\set VERBOSITY default
SELECT template FROM postal_code_templates WHERE NOT builtin ORDER BY slot;

SELECT remove_country_format(cc) FROM unnest(ARRAY['XA', 'XB', 'XC', 'XD', 'XE', 'XF']) cc;

-- and when all 51 slots are taken
BEGIN;
SELECT count(add_country_template('XA', t)) AS filled FROM (
   SELECT t FROM (
      SELECT repeat('N', a) || repeat('A', b) AS t FROM generate_series(1, 6) a, generate_series(1, 4) b
      UNION ALL SELECT repeat('X', c) FROM generate_series(1, 9) c
      UNION ALL SELECT repeat('N', c) FROM generate_series(1, 9) c
      UNION ALL SELECT repeat('A', c) FROM generate_series(1, 6) c
   ) q
   WHERE t NOT IN (SELECT template FROM postal_code_templates)
   ORDER BY t
   LIMIT 51 - (SELECT count(*) FROM postal_code_templates)
) f;
SELECT count(*) AS slots, min(slot), max(slot) FROM postal_code_templates;
SELECT add_country_template('XA', 'NNNNNNNNNNN');
ROLLBACK;

-- ===== Countries whose own letters are part of the code ====================
-- The British Virgin Islands write VG1110, Andorra AD500, Azerbaijan AZ 1000:
-- the ISO letters are in the code. A template starting CC means that: the
-- letters are optional on input, must be the country's own, and are neither
-- stored nor written back, so all the spellings are one value in the UPU form.
SELECT add_country_template('XG', 'CCNNNN');
SELECT add_country_template('XH', 'CC NNNN');
SELECT add_country_template('XJ', 'CCN-NNNN');
SELECT postal_code('XG1110', 'XG') AS a, postal_code('xg-1110', 'XG') AS b, postal_code('1110', 'XG') AS c,
       'XG-XG1110'::postal_code AS d, 'XG-XG-1110'::postal_code AS e, 'XG-1110'::postal_code AS f;
SELECT postal_code('XG1110', 'XG') = postal_code('1110', 'XG') AS same_value, 'XG-XG1110'::postal_code::text AS written_back;
SELECT 'XH-XH 1000'::postal_code AS a, 'XH-xh1000'::postal_code AS b, 'XH-1000'::postal_code AS c;
SELECT 'XJ-XJ1-1100'::postal_code AS a, 'XJ-1-1100'::postal_code AS b;
-- somebody else's letters are not the country's
SELECT 'XG-AB1110'::postal_code;
SELECT 'XG-X1110'::postal_code;
SELECT 'XG-XG'::postal_code;
SELECT to_postal_code('XG-AB1110') AS null_not_error, is_valid('XG1110', 'XG') AS yes, is_valid('AB1110', 'XG') AS no;
-- ... and it works for fragments, ranges and the operator the same way
SELECT lower_bound('XG-XG11') AS lo, upper_bound('XG-XG11') AS hi, lower_bound('XG-11') = lower_bound('XG-XG11') AS same;
SELECT 'XG-XG1110'::postal_code % 'XG-XG11' AS yes, 'XG-1110'::postal_code % 'XG-12' AS no;
-- the real ones
SELECT postal_code('VG1110', 'VG') AS vg, postal_code('AD500', 'AD') AS ad, postal_code('AZ 1000', 'AZ') AS az,
       postal_code('HT6110', 'HT') AS ht, postal_code('LC04 101', 'LC') AS lc, postal_code('LV-1001', 'LV') AS lv;
SELECT 'BB-BB11000'::postal_code AS bb, 'KY-KY1-1100'::postal_code AS ky;
SELECT postal_code('XX1110', 'VG');
SELECT remove_country_format(cc) FROM unnest(ARRAY['XG', 'XH', 'XJ']) cc;

-- ===== Real-world examples: foreign registered offices in Companies House ====
-- The postcodes of non-UK registered offices (distinct values, no company
-- names), country first. Most are fine; NULL is the right answer for the
-- junk ones ("NOT APPLICABLE", a UK-style code filed under Surrey).
SELECT cc, code, to_postal_code(code, cc) AS parsed
FROM (VALUES
   ('AT', '1010'),
   ('BM', 'HM19'),
   ('CA', 'M5H 2M8'),
   ('CA', 'V4N 5W5'),
   ('GB', 'CP9 4PX'),
   ('GG', 'GY1 1ZX'),
   ('GG', 'GY1 3RH'),
   ('GG', 'GY1 4NA'),
   ('GG', 'GY4 6DY'),
   ('GI', 'GX11 1AA'),
   ('IM', 'IM1 1LB'),
   ('IM', 'IM1 2PT'),
   ('IM', 'IM1 2SD'),
   ('IM', 'IM2 1QB'),
   ('IM', 'IM2 4DF'),
   ('IM', 'IM8 1GB'),
   ('JE', 'JE1 0BD'),
   ('JE', 'JE1 1AD'),
   ('JE', 'JE1 1BX'),
   ('JE', 'JE1 1GL'),
   ('JE', 'JE1 1RB'),
   ('JE', 'JE1 1SG'),
   ('JE', 'JE1 2LH'),
   ('JE', 'JE1 2TR'),
   ('JE', 'JE2 3NY'),
   ('JE', 'JE2 3QA'),
   ('JE', 'JE2 3RA'),
   ('JE', 'JE4 8PW'),
   ('JE', 'JE4 8PX'),
   ('JE', 'JE4 9WG'),
   ('LU', '1116'),
   ('LU', '2411'),
   ('LU', '8070'),
   ('LU', 'L - 2226'),
   ('LU', 'L-1528'),
   ('MH', '96960'),
   ('US', '19808'),
   ('US', '23219'),
   ('US', '34990'),
   ('US', '89146'),
   ('VG', 'NOT APPLICABLE'),
   ('VG', 'VG1110')
) v(cc, code) ORDER BY cc, code;

-- Spacing is tidied, nothing else: surrounding and doubled spaces, and spaces
-- next to a hyphen, which is how "L - 2226" turns up in real data.
SELECT t AS written, to_postal_code(t, cc) AS parsed
FROM (VALUES ('LU', ' L - 2226 '), ('LU', 'L -2226'), ('US', '90210 - 1234'), ('GB', '  SW1A   1AA '),
             ('CA', 'k1a  0b1'), ('XX', '12345'), ('VG', ' VG  1110'), ('FR', E'75008\t')) v(cc, t);
SELECT ' us - 90210 '::postal_code AS a, E'GB-SW1A\n1AA'::postal_code AS b, 'ca - K1A  0B1'::postal_code AS c;
SELECT lower_bound(' GB - SW1A ') AS lo, ' GB-SW1A'::postal_code % ' GB-SW ' AS matches;
SELECT postal_code(' 90210 ', ' us ');
SELECT 'U S-90210'::postal_code;
SELECT 'US-90 210'::postal_code;

-- ===== Obvious variants ======================================================
-- What a format accepts as written is taken as written. Only if that fails
-- are these tried: the country's own letters dropped ("MH96960"), spaces and
-- hyphens swapped ("1050 010"), spaces dropped ("06 830"). They re-spell the
-- same characters, so they recognise a spelling but cannot make a non-code one.
SELECT cc, written, to_postal_code(written, cc) AS parsed
FROM (VALUES ('MH', 'MH96960'), ('MH', 'MH 96960'), ('MH', 'mh-96960'), ('AI', 'AI2640'), ('AI', 'AI 2640'),
             ('US', 'US90210'), ('US', 'US 90210-1234'), ('CA', 'CA K1A 0B1'), ('FR', 'FR 75008'),
             ('LU', 'L1471'), ('LU', 'L 1820'), ('LU', 'L-1 452'), ('LU', 'LU-L-1471'), ('LU', 'LU1471'),
             ('US', '06 830'), ('US', '19 801'), ('DE', '10 117'), ('CA', 'K1A0B1'), ('CA', 'K1A-0B1'),
             ('PT', '1050 010'), ('PT', '1050-010'), ('PT', '1050010'), ('GB', 'SW1A-1AA'), ('GB', 'SW1A1AA'),
             ('BR', '01310 100'), ('VG', 'VG 1110'), ('VG', 'VG-1110')) v(cc, written);

-- Jersey, Guernsey and the Isle of Man codes start with the country's own
-- letters, so they must keep working as written and the retry must not turn
-- a broken one into a valid one.
SELECT cc, written, to_postal_code(written, cc) AS parsed
FROM (VALUES ('IM', 'IM1 1AA'), ('JE', 'JE4 9WG'), ('GG', 'GY1 1ZX'), ('IM', 'IM1 SPT'), ('JE', 'JEL 0BD'),
             ('IM', 'IM1 2P'), ('JE', 'JE1 1G'), ('GG', 'GG1 1AA'), ('IM', 'IM 1AA')) v(cc, written);

-- ... and none of it reaches address text, which is a data-cleaning job, not a postcode one
SELECT cc, written, to_postal_code(written, cc) AS parsed
FROM (VALUES ('US', 'DE 19801'), ('US', 'DELAWARE 19803'), ('AU', 'NSW 2000'), ('CA', 'ON L6M 0A8'),
             ('PT', '1200-445 LISBON'), ('IT', 'CAP 00144'), ('IE', 'DUBLIN 2'), ('US', 'PO BOX 3085'),
             ('US', '9021'), ('US', '902101'), ('LU', 'L-12345')) v(cc, written);

-- the same for fragments, ranges and the operator
SELECT lower_bound('US-US 90') AS a, lower_bound('LU-L 14') AS b, upper_bound('PT-1050 0') AS c;
SELECT 'US-90210'::postal_code % 'US-US90' AS yes, 'US-90210'::postal_code % 'US-9 02' AS also_yes, 'US-90210'::postal_code % 'US-91' AS no;

-- ===== The UAE =================================================================
-- The UAE has no postal codes, but two schemes work like them. Abu Dhabi assigns
-- 5-digit codes by district (20000 central Abu Dhabi, 23251 Khalifa City, 20014 Yas
-- Island). Dubai numbers every building with a 10-digit Makani code, written
-- NNNNN NNNNN, which is what GeoNames holds for the UAE. One format, NNNNN with an
-- optional second block, holds both; the world view says what it is. PO Box numbers,
-- which is what UAE addresses mostly give, are not codes and are rejected.
SELECT postal_code('20000', 'AE') AS abu_dhabi, postal_code('18038 79169', 'AE') AS dubai_makani,
       postal_code('1803879169', 'AE') AS b, 'AE-18038-79169'::postal_code AS c;
SELECT written, to_postal_code(written, 'AE') AS parsed
FROM (VALUES ('20000'), ('23251'), ('20014'), ('18038 79169'), ('71241'), ('450676'), ('PO BOX 413383'),
             ('P.O. BOX 98444'), ('1204'), ('00000'), ('18038 7916')) v(written);
SELECT outcode('AE-18038 79169'::postal_code) AS makani_head, outcode('AE-20000'::postal_code) AS abu_dhabi_is_its_own;
SELECT iso2, format, basis, left(note, 50) AS note FROM postal_code_world WHERE iso2 IN ('AE', 'OM', 'QA');

-- ===== Built-in and user assignments =========================================
-- What ships with the extension is separate from what users assign, so a dump
-- can carry exactly the latter. The view shows both; a user row wins.
SELECT iso2, format_name, builtin FROM postal_code_country_formats WHERE iso2 IN ('US', 'GB', 'GG', 'IE') ORDER BY iso2;
BEGIN;
SELECT add_country_format('GG', 'FR');            -- override a built-in assignment
SELECT iso2, format_name, builtin FROM postal_code_country_formats WHERE iso2 = 'GG';
SELECT remove_country_format('IE');               -- removing a built-in one leaves a tombstone
SELECT count(*) AS ie_rows FROM postal_code_country_formats WHERE iso2 = 'IE';
SAVEPOINT s;
SELECT 'IE-D02'::postal_code;
ROLLBACK TO s;
SELECT iso2, format_name FROM postal_code_user_countries WHERE iso2 IN ('GG', 'IE') ORDER BY iso2;
SELECT add_country_format('IE', 'IE');            -- and it can be put back
SELECT 'IE-D02'::postal_code;
SELECT remove_country_format('GG');
SELECT remove_country_format('GG');               -- (removing twice is harmless)
ROLLBACK;
SELECT iso2, format_name, builtin FROM postal_code_country_formats WHERE iso2 IN ('GG', 'IE') ORDER BY iso2;

-- ===== outcode() and district() ==============================================
-- The area part of a postcode, as a complete valid postcode of its own.
-- district() is the same function under its other name.
SELECT outcode('GB-SW1A 1AA') AS gb, outcode('US-90210-1234') AS us, outcode('CA-K1A 0B1') AS ca,
       outcode('IE-A65 F4E2') AS ie, outcode('BR-01310-100') AS br;
SELECT district('GB-LS24 9JT') AS district, district('GB-LS24 9JT') = outcode('GB-LS24 9JT') AS same_function;

-- idempotent: an outcode is its own outcode
SELECT outcode('GB-SW1A') AS gb, outcode(outcode('IE-A65 F4E2')) AS ie, outcode('US-90210') AS us;

-- NULL where the leading digits are only implicitly an outcode (FR, CZ, LU),
-- and for the end-of-country bound, which is not a postcode
SELECT outcode('FR-75001') IS NULL AS fr, outcode('CZ-110 00') IS NULL AS cz,
       outcode('LU-L-1311') IS NULL AS lu, outcode('US-~') IS NULL AS end_of_country_bound;

-- full postcodes group by their outcode
CREATE TEMP TABLE full_codes (pc postal_code);
INSERT INTO full_codes VALUES ('GB-SW1A 1AA'), ('GB-SW1A 2AB'), ('GB-SW1B 1AA'), ('GB-LS1 4AP'),
   ('US-90210-1234'), ('US-90210-5678'), ('US-90211'), ('CA-K1A 0B1'), ('CA-K1A 0B2'), ('CA-K1B 0A1'),
   ('IE-A65 F4E2'), ('IE-A65 TV22'), ('FR-75001'), ('FR-75002');
SELECT outcode(pc) AS outcode, count(*) FROM full_codes GROUP BY 1 ORDER BY 1 NULLS LAST;

-- properties that must hold for every value in the fixture
SELECT count(*) FILTER (WHERE outcode(pc) IS NOT NULL) AS with_outcode,
       count(*) FILTER (WHERE outcode(pc) IS NULL) AS without,
       count(*) FILTER (WHERE outcode(pc) > pc) AS outcode_sorts_after_its_code,
       count(*) FILTER (WHERE outcode(outcode(pc)) IS DISTINCT FROM outcode(pc)) AS not_idempotent,
       count(*) FILTER (WHERE outcode(pc) IS NOT NULL AND NOT (pc <@ postal_prefix(outcode(pc)::text))) AS not_in_its_outcodes_range,
       count(*) FILTER (WHERE outcode(pc) IS NOT NULL AND outcode(pc) <> lower_bound(outcode(pc)::text)) AS outcode_not_first_of_its_range
FROM (SELECT pc FROM addr UNION ALL SELECT pc FROM full_codes) all_codes;

-- IMMUTABLE (it only reads the value's own bits, never the country table), so
-- unlike postal_code(...) it can be indexed
CREATE INDEX addr_outcode_idx ON addr (outcode(pc));
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT pg_temp.uses_index_cond($q$ SELECT * FROM addr WHERE outcode(pc) = 'GB-PH26' $q$) AS outcode_expression_index_used;
RESET enable_seqscan;
RESET enable_bitmapscan;
DROP INDEX addr_outcode_idx;

-- THE SAFETY NET. Folding postal_prefix() into a plan would let a cached
-- plan keep a range computed under a country assignment that has since
-- changed, so the folded plan depends on postal_code_country_formats and a
-- trigger invalidates it whenever that table changes. Austria is assigned the
-- plain-5-digit format, a row is stored, a statement is prepared (its plan is
-- cached); then Country XW is reassigned to the Czech format, which renders with
-- a space. The same prepared statement must now mean the CZ range -- and so
-- return the CZ-format row, not the old FR-format one.
SELECT add_country_format('XW', 'FR');
INSERT INTO addr (pc) VALUES ('XW-12345');
PREPARE xw_prefix AS SELECT pc FROM addr WHERE pc <@ postal_prefix('XW-12');
EXECUTE xw_prefix;
EXECUTE xw_prefix;
SELECT add_country_format('XW', 'CZ');
INSERT INTO addr (pc) VALUES ('XW-12345');
EXECUTE xw_prefix;
DEALLOCATE xw_prefix;
SELECT remove_country_format('XW');
DELETE FROM addr WHERE pc::text LIKE 'XW-%';


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
