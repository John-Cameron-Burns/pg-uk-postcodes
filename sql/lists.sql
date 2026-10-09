-- Schemes defined by a list of codes: add_country_list(), add_country_list_from(). See LIST_SCHEMES.md.
-- A list is a language like any other (same ranks, ranges, locks), built straight from the codes.

\set SHOW_CONTEXT never

-- a small list, given in no particular order
SELECT add_country_list('QL', ARRAY['47110', '47190', '47210', '47220', '47300', '01110', '01120', '01130', '47191']);
SELECT version, kind, source, pattern = '' AS no_pattern FROM postal_code_languages WHERE iso2 = 'QL';
SELECT code FROM postal_code_list_codes WHERE iso2 = 'QL' ORDER BY code;
SELECT iso2, format_name FROM postal_code_country_formats WHERE iso2 = 'QL';

-- ... which now works as a country's codes
SELECT 'QL-47110'::postal_code AS code, 'ql-47110'::postal_code = 'QL-47110'::postal_code AS either_case,
       postal_code('47110', 'QL') AS two_arguments;
SELECT is_valid_postal_code('QL-47110') AS listed, is_valid_postal_code('QL-47111') AS not_listed,
       to_postal_code('QL-99999') IS NULL AS lenient_null;
SELECT 'QL-47111'::postal_code;

-- ranked in byte order, so the type sorts as the text does
SELECT code::text FROM (SELECT 'QL-' || c AS code FROM unnest(ARRAY['47300', '01120', '47110', '01110', '47191']) c) v
ORDER BY code::postal_code;

-- prefix ranges are exact, whatever is and is not in the list
SELECT postal_prefix('QL-47') AS division, lower_bound('QL-47'), upper_bound('QL-47');
SELECT postal_prefix('QL-471') AS group_471, lower_bound('QL-471'), upper_bound('QL-471');
SELECT count(*) AS in_division_47 FROM (SELECT ('QL-' || c)::postal_code AS pc FROM unnest(ARRAY['47110', '47190', '47191', '47210', '01110']) c) v
WHERE pc <@ postal_prefix('QL-47');
SELECT outcode('QL-47110') IS NULL AS no_outcode_none_is_a_prefix_of_another;

-- a column locked to the scheme takes bare codes with postal_code(), and refuses another country's
CREATE TEMP TABLE firms (id serial, sic postal_code('QL'));
INSERT INTO firms (sic) VALUES ('QL-47110'), (postal_code('47190', 'QL')), ('QL-01110');
INSERT INTO firms (sic) VALUES ('US-90210');
INSERT INTO firms (sic) VALUES ('QL-47112');
SELECT sic FROM firms ORDER BY sic;

-- the same codes again, in another order, change nothing
SELECT add_country_list('QL', ARRAY['01130', '01120', '01110', '47191', '47190', '47110', '47210', '47220', '47300']);
SELECT version FROM postal_code_languages WHERE iso2 = 'QL' ORDER BY version;

-- the parts of a list are a pattern of their own (it only splits; the list says which codes there are)
SELECT add_country_list('QL', ARRAY['47110', '47190', '47210', '47220', '47300', '01110', '01120', '01130', '47191'],
                        '/(?<division>\d{2})(?<group>\d)(?<class>\d)(?<subclass>\d)/');
SELECT version, parts_pattern FROM postal_code_languages WHERE iso2 = 'QL' ORDER BY version;
SELECT ord, name FROM postal_code_parts WHERE iso2 = 'QL' ORDER BY ord;
SELECT parts('QL-47110'::postal_code);
SELECT part('QL-47191'::postal_code, 'division') AS division, part('QL-47191'::postal_code, 'group') AS grp,
       part('QL-47191'::postal_code, 'subclass') AS subclass;
SELECT prefix_of('QL-47191'::postal_code, 'division') = postal_prefix('QL-47') AS division_level,
       prefix_of('QL-47191'::postal_code, 'class') = postal_prefix('QL-4719') AS class_level;
SELECT sic, prefix_of(sic, 'division') AS division, count(*) OVER (PARTITION BY prefix_of(sic, 'division')) AS in_division
FROM firms ORDER BY sic;
-- parts can be removed again, and a list with none says so
SELECT add_country_list('QL', ARRAY['47110', '47190', '47210', '47220', '47300', '01110', '01120', '01130', '47191']);
SELECT count(*) AS parts_left FROM postal_code_parts WHERE iso2 = 'QL';
SELECT version FROM postal_code_languages WHERE iso2 = 'QL' ORDER BY version;
SELECT part('QL-47110'::postal_code, 'division');

-- different codes are the next language, and what was stored under the first still reads as it was written
SELECT add_country_list('QL', ARRAY['47110', '47190', '47210', '99999']);
SELECT version, source FROM postal_code_languages WHERE iso2 = 'QL' ORDER BY version;
SELECT 'QL-99999'::postal_code AS new_code;
SELECT sic FROM firms ORDER BY sic;
SELECT 'QL-47300'::postal_code;

-- from a query
CREATE TEMP TABLE sic_demo (code text);
INSERT INTO sic_demo VALUES ('62010'), ('62020'), ('62090'), ('63110'), ('63120'), ('62012');
SELECT add_country_list_from('QM', 'SELECT code FROM sic_demo');
SELECT version, source FROM postal_code_languages WHERE iso2 = 'QM';
SELECT count(*) AS codes FROM postal_code_list_codes WHERE iso2 = 'QM';
SELECT add_country_list_from('QM', 'SELECT code FROM sic_demo WHERE false');

-- a pattern and a list that denote the same codes are one language
SELECT add_country_template('QO', '/[A-C]\d/');
SELECT add_country_list('QO', (SELECT array_agg(chr(64 + l) || d) FROM generate_series(1, 3) l, generate_series(0, 9) d));
SELECT iso2, version, kind FROM postal_code_languages WHERE iso2 = 'QO' ORDER BY version;
SELECT add_country_list('QK', ARRAY['AA', 'AB', 'BA']);
SELECT add_country_template('QK', '/AA|AB|BA/');
SELECT iso2, version, kind FROM postal_code_languages WHERE iso2 = 'QK' ORDER BY version;

-- far more codes than a pattern holds comfortably: about 31,000 of the 100,000 five-digit strings, picked pseudo-randomly
CREATE TEMP TABLE big AS
   SELECT lpad(i::text, 5, '0') AS code FROM generate_series(0, 99999) i WHERE get_byte(decode(md5(i::text), 'hex'), 0) < 80;
SELECT count(*) > 25000 AS a_long_list FROM big;
SELECT add_country_list_from('QN', 'SELECT code FROM big');
SELECT (SELECT count(*) FROM big) = (SELECT count(*) FROM postal_code_list_codes WHERE iso2 = 'QN') AS all_stored;
ALTER TABLE big ADD COLUMN pc postal_code;
UPDATE big SET pc = ('QN-' || code)::postal_code;
SELECT count(*) AS out_of_order FROM (SELECT code, lag(code) OVER (ORDER BY pc) AS prev FROM big) o WHERE prev > code;
SELECT count(*) AS round_trip_failures FROM big WHERE pc::text <> 'QN-' || code;
-- not in the list: refused
SELECT count(*) AS unlisted_tried, count(*) FILTER (WHERE is_valid_postal_code('QN-' || c)) AS unlisted_accepted
FROM (SELECT lpad(i::text, 5, '0') AS c FROM generate_series(0, 99999, 9) i) s WHERE c NOT IN (SELECT code FROM big);
-- every prefix range agrees with plain text (40 prefixes of 1 to 4 digits, drawn from the codes). The range is worked out
-- once per prefix: MATERIALIZED, because PostgreSQL would otherwise fold the CTE into the query and work it out again for
-- every row it is compared with (about 40 microseconds each).
WITH pf AS (SELECT p FROM (SELECT DISTINCT left(code, k) AS p FROM big, generate_series(1, 4) k) d ORDER BY md5(p) LIMIT 40),
     rng AS MATERIALIZED (SELECT p, postal_prefix('QN-' || p) AS r FROM pf),
     chk AS (SELECT p, (SELECT count(*) FROM big WHERE pc <@ rng.r) = (SELECT count(*) FROM big WHERE code LIKE rng.p || '%') AS agrees FROM rng)
SELECT count(*) AS prefixes_checked, count(*) FILTER (WHERE NOT agrees) AS disagreeing FROM chk;

-- a list that cannot be one is refused, saying where
SELECT add_country_list('QX', ARRAY['A', 'B', 'A']);
SELECT add_country_list('QX', ARRAY['AB', 'ab']);
SELECT add_country_list('QX', ARRAY['A', '']);
SELECT add_country_list('QX', ARRAY['A', NULL]);
SELECT add_country_list('QX', ARRAY[repeat('1', 41)]);
SELECT add_country_list('QX', ARRAY['A', E'B\tC']);
SELECT add_country_list('QX', ARRAY[]::text[]);
SELECT add_country_list('QX', NULL);
SELECT add_country_list('Q', ARRAY['A']);
SELECT add_country_list_from('QX', 'SELECT nothing FROM nowhere');
SELECT count(*) AS leftovers FROM postal_code_languages WHERE iso2 = 'QX';
-- ... or needs more states than the transitions can number (150,000 random 8-digit codes)
SELECT add_country_list('QX', (SELECT array_agg(DISTINCT substr(translate(md5(i::text), 'abcdef', '012345'), 1, 8)) FROM generate_series(1, 150000) i));
-- the parts pattern is checked against the codes
SELECT add_country_list('QX', ARRAY['12345', 'ABCDE'], '/(?<a>\d{2})(?<b>\d{3})/');
SELECT add_country_list('QX', ARRAY['123'], '/(?<a>\d{1,2})(?<b>\d{1,2})/');
SELECT add_country_list('QX', ARRAY['123'], '/\d{3}/');
SELECT add_country_list('QX', ARRAY['123'], '/(?<a>\d/');
SELECT count(*) AS leftovers FROM postal_code_languages WHERE iso2 = 'QX';

-- a language and its codes are permanent; a list's parts can be named or removed
UPDATE postal_code_list_codes SET code = '00000' WHERE iso2 = 'QM' AND code = '62010';
DELETE FROM postal_code_list_codes WHERE iso2 = 'QM';
TRUNCATE postal_code_list_codes;
UPDATE postal_code_languages SET source = 'something else' WHERE iso2 = 'QM';
UPDATE postal_code_languages SET kind = 'pattern', pattern = '\d{5}' WHERE iso2 = 'QM';
UPDATE postal_code_languages SET parts_pattern = '(?<a>\d{2})(?<b>\d{3})' WHERE iso2 = 'QM';
UPDATE postal_code_languages SET parts_pattern = '(?<a>\d' WHERE iso2 = 'QM';
SELECT parts_pattern FROM postal_code_languages WHERE iso2 = 'QM';
-- a pattern language cannot grow a parts pattern, and the two kinds keep to their own fields
UPDATE postal_code_languages SET parts_pattern = '(?<a>\d)' WHERE iso2 = 'QO' AND kind = 'pattern';
\set VERBOSITY terse
INSERT INTO postal_code_languages (iso2, version, source, pattern, kind) VALUES ('QZ', 1, 'x', '\d', 'list');
INSERT INTO postal_code_languages (iso2, version, source, pattern, kind) VALUES ('QZ', 1, 'x', '', 'pattern');
\set VERBOSITY default

-- the view of the world shows what a country uses (here a built-in country given a list of its own)
SELECT add_country_list('NO', ARRAY['0150', '0151', '0152']);
SELECT iso2, format FROM postal_code_world WHERE iso2 IN ('NO', 'PL') ORDER BY iso2;
