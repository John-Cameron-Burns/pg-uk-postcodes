-- Named parts: part(), parts(), prefix_of(), the postal_code_parts view, and the ambiguity check.
-- A pattern names a part of a code with (?<name>...); a name never changes which codes are valid or how
-- they are stored. See NAMED_PARTS.md.

-- errors from inside the extension's own PL/pgSQL functions would otherwise record the line they came from
\set SHOW_CONTEXT never

-- the compiled formats: pieces of text, named as to_char names them (GB)
SELECT code,
       part(code, 'area')     AS area,
       part(code, 'district') AS district,
       part(code, 'sector')   AS sector,
       part(code, 'walk')     AS walk
FROM (VALUES ('GB-SW1A 1AA'::postal_code), ('GB-EC4Y 0HQ'), ('GB-M1 1AA'), ('GB-W1A'), ('GB-LS24'),
             ('GG-GY1 1AA'), ('GB-BX5 5AT'), ('GB-GX11 1AA')) v(code);

SELECT parts('GB-SW1A 1AA') AS gb_full, parts('GB-SW1A') AS gb_outcode,
       parts('US-90210-1234') AS us_zip4, parts('US-90210') AS us_zip5,
       parts('CA-K1A 0B1') AS ca_full, parts('CA-K1A') AS ca_fsa,
       parts('IE-A65 F4E2') AS ie_full, parts('IE-D6W') AS ie_key,
       parts('BR-01310-100') AS br_full, parts('BR-01310') AS br_base;

-- Royal Mail's levels are everything up to and including a piece: prefix_of(), not part()
SELECT code, name, prefix_of(code, name) = postal_prefix(expect) AS as_expected
FROM (VALUES ('GB-SW1A 1AA'::postal_code, 'area', 'GB-SW'),
             ('GB-SW1A 1AA', 'district', 'GB-SW1A'),
             ('GB-SW1A 1AA', 'sector', 'GB-SW1A 1'),
             ('GB-SW1A 1AA', 'walk', 'GB-SW1A 1AA'),
             ('GB-EC4Y 0HQ', 'district', 'GB-EC4Y'),
             ('US-90210-1234', 'zip5', 'US-90210'),
             ('US-90210-1234', 'plus4', 'US-90210-1234'),
             ('CA-K1A 0B1', 'fsa', 'CA-K1A'),
             ('IE-A65 F4E2', 'routing_key', 'IE-A65')) v(code, name, expect);

-- the district piece is not Royal Mail's district, which is why both functions exist
SELECT part('GB-SW1A 1AA', 'district') AS piece,
       prefix_of('GB-SW1A 1AA', 'district') AS level,
       lower_bound('GB-SW1A') AS level_starts_at,
       outcode('GB-SW1A 1AA') AS same_as_outcode;

-- a part the code does not have is NULL; so is anything given NULL
SELECT part('GB-SW1A', 'sector') IS NULL AS no_sector,
       part('GB-SW1A', 'walk') IS NULL AS no_walk,
       prefix_of('GB-SW1A', 'walk') IS NULL AS no_walk_prefix,
       part('US-90210', 'plus4') IS NULL AS no_plus4,
       part(NULL::postal_code, 'area') IS NULL AS null_code,
       part('GB-SW1A 1AA', NULL) IS NULL AS null_name,
       parts(NULL::postal_code) IS NULL AS null_parts;

-- group and filter by a level
CREATE TEMP TABLE addr (id serial, pc postal_code);
INSERT INTO addr (pc) VALUES ('GB-SW1A 1AA'), ('GB-SW1A 2AA'), ('GB-SW1A 2BB'), ('GB-SW1V 1AA'),
                              ('GB-SW1A'), ('GB-EC4Y 0HQ'), ('US-90210-1234'), ('US-90210'), ('US-10001');
SELECT prefix_of(pc, 'district') AS district, count(*)
FROM addr WHERE pc::text LIKE 'GB-%' GROUP BY 1 ORDER BY 1;
SELECT pc FROM addr WHERE pc <@ prefix_of('GB-SW1A 1AA', 'sector') ORDER BY pc;
SELECT pc FROM addr WHERE pc <@ prefix_of('GB-SW1A 2AA', 'district') ORDER BY pc;

-- mistakes are errors, and say what there is
SELECT part('GB-SW1A 1AA', 'postcode');
SELECT part('GB-SW1A 1AA', 'District');
SELECT part('FR-75001', 'department');
SELECT parts('FR-75001');
SELECT prefix_of('PL-00-950', 'x');
SELECT part('US-~', 'zip5');

-- what each country's parts are
SELECT iso2, format, ord, name FROM postal_code_parts
WHERE iso2 IN ('GB', 'GG', 'US', 'CA', 'IE', 'BR', 'FR', 'PL') ORDER BY iso2, ord;

-- a pattern of your own names its parts: a regular expression with (?<name>...)
SELECT add_country_template('QP', '/(?<major>\d{2})-(?<minor>\d{3})(-(?<extra>[A-C]))?/');
SELECT parts('QP-12-345'), parts('QP-12-345-B');
SELECT part('QP-12-345-B', 'extra') AS extra, part('QP-12-345', 'extra') IS NULL AS no_extra;
SELECT prefix_of('QP-12-345-B', 'minor') = postal_prefix('QP-12-345') AS minor_level;
SELECT ord, name FROM postal_code_parts WHERE iso2 = 'QP' ORDER BY ord;

-- nesting: the outer part includes its children; an alternation: only one branch's part is present
SELECT add_country_template('QR', '/(?<code>(?<first>\d{2})(?<second>\d{2})?)|(?<word>[A-C]{3})/');
SELECT parts('QR-1234'), parts('QR-12'), parts('QR-ABC');

-- the names are labels: the same codes written or named differently relabel the language, they do not make a new version
SELECT add_country_template('QP', '/(?<a>\d{2})-(?<b>\d{3})(-(?<c>[A-C]))?/');
SELECT version, source FROM postal_code_languages WHERE iso2 = 'QP' ORDER BY version;
SELECT parts('QP-12-345-B') AS relabelled, 'QP-12-345-B'::postal_code = 'QP-12-345-B'::postal_code AS same_value;
-- ... and they can go altogether, even though the pattern is written quite differently
SELECT add_country_template('QP', '/\d{2}-\d{3}(-[A-C])?/');
SELECT version, source FROM postal_code_languages WHERE iso2 = 'QP' ORDER BY version;
SELECT count(*) AS parts_left FROM postal_code_parts WHERE iso2 = 'QP';
SELECT part('QP-12-345', 'a');
SELECT add_country_template('QP', '/(?<major>\d{2})-(?<minor>\d{3})(-(?<extra>[A-C]))?/');
SELECT version, source FROM postal_code_languages WHERE iso2 = 'QP' ORDER BY version;
-- ... but a different set of codes is a new language
SELECT add_country_template('QP', '/(?<a>\d{2})-(?<b>\d{4})/');
SELECT version, source FROM postal_code_languages WHERE iso2 = 'QP' ORDER BY version;
SELECT 'QP-12-3456'::postal_code = 'QP-12-3456'::postal_code AS version2_works, parts('QP-12-3456');
-- a built-in language is never edited: another spelling of it is the country's next language
SELECT add_country_template('DK', '/(?<a>\d{4})/');
SELECT version, builtin FROM postal_code_languages WHERE iso2 = 'DK' ORDER BY version;

-- a language still cannot change what it means; only be written another way
UPDATE postal_code_languages SET pattern = '\d{5}' WHERE iso2 = 'QP' AND version = 1;
UPDATE postal_code_languages SET pattern = '(?<major>\d{2})-(?<minor>\d{3})(-[A-D])?' WHERE iso2 = 'QP' AND version = 1;
UPDATE postal_code_languages SET source = 'x' WHERE iso2 = 'QP' AND version = 1;
DELETE FROM postal_code_languages WHERE iso2 = 'QP';
UPDATE postal_code_languages SET pattern = '(?<x>\d{2})-(?<y>\d{4})' WHERE iso2 = 'QP' AND version = 2;
SELECT pattern FROM postal_code_languages WHERE iso2 = 'QP' ORDER BY version;

-- a pattern whose parts could split some code two ways is refused, with an example
SELECT add_country_template('QS', '/(?<a>\d{1,2})(?<b>\d{1,2})/');
SELECT add_country_template('QS', '/(?<a>[A-C]{1,2})(?<b>[A-C]?\d)/');
-- ... also when there are too many codes to try them all
SELECT postal_code_pattern_size('/\d{1,4}\d{1,4}/') > 10000000 AS more_than_tried_exhaustively;
SELECT add_country_template('QS', '/(?<a>\d{1,4})(?<b>\d{1,4})/');
-- ... and a pattern that is fine is accepted, whatever its size
SELECT add_country_template('QS', '/(?<area>[A-Z]{1,2})(?<district>\d[A-Z\d]?)( (?<sector>\d)(?<walk>[A-Z]{2}))?/');
SELECT postal_code_pattern_size('/[A-Z]{1,2}\d[A-Z\d]?( \d[A-Z]{2})?/') > 10000000 AS also_more_than_tried_exhaustively;
SELECT parts('QS-SW1A 1AA');
SELECT add_country_template('QS', '/(?<a>\d{2})(?<b>\d{1,2})/');
SELECT parts('QS-1234'), parts('QS-123');

-- parts that cannot work are refused when the pattern is defined (a repeat INSIDE a part is fine)
SELECT add_country_template('QT', '/(?<a>\d)(?<a>\d)/');
SELECT add_country_template('QT', '/(?<a>\d){2}/');
SELECT add_country_template('QT', '/(?<a>\d{1,3})/');
SELECT add_country_template('QT', '/(?<a>\d?)/');
SELECT add_country_template('QT', '/(?<Name>\d)/');
SELECT add_country_template('QT', '/(?<=a)\d/');
SELECT add_country_template('QT', '/(?!a)\d/');
SELECT add_country_template('QT', '/(?<a>\d)(?<b/');
SELECT add_country_template('QT', '(?<a>NN)-(?<b>NNN)');

-- the helpers
SELECT postal_code_pattern_part_names('(?<x>\d)(?<y>\d)\d') AS names,
       postal_code_pattern_part_names('\d{5}') AS none;
SELECT postal_code_same_codes('(?<a>\d{2})-(?<b>\d{3})', '\d\d-\d\d\d') AS written_differently,
       postal_code_same_codes('\d{2}|[A-C]', '[A-C]|\d{2}') AS order_of_alternatives,
       postal_code_same_codes('\d{2}-\d{3}', '\d{2}-\d{4}') AS a_digit_more,
       postal_code_same_codes('\d{2}(-\d{3})?', '\d{2}-\d{3}') AS optional_part,
       postal_code_same_codes('\d{2}', '[0-9]{2}') AS a_class;
SELECT postal_code_parts_check('(?<x>\d{2})(?<y>\d)') IS NULL AS fine;
SELECT postal_code_parts_check('\d{1,2}\d{1,2}') IS NULL AS no_parts_nothing_to_check;

-- to_char(postcode, text) still works, and says it is deprecated
SELECT to_char('SW1A 1AA'::postcode, 'AD SW');
SELECT obj_description('to_char(postcode, text)'::regprocedure, 'pg_proc') LIKE 'DEPRECATED since 2.1:%' AS deprecated;
