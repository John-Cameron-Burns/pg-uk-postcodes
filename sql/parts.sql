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

SELECT parts('GB-SW1A 1AA'::postal_code) AS gb_full, parts('GB-SW1A'::postal_code) AS gb_outcode,
       parts('US-90210-1234'::postal_code) AS us_zip4, parts('US-90210'::postal_code) AS us_zip5,
       parts('CA-K1A 0B1'::postal_code) AS ca_full, parts('CA-K1A'::postal_code) AS ca_fsa,
       parts('IE-A65 F4E2'::postal_code) AS ie_full, parts('IE-D6W'::postal_code) AS ie_key,
       parts('BR-01310-100'::postal_code) AS br_full, parts('BR-01310'::postal_code) AS br_base;

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
SELECT part('GB-SW1A 1AA'::postal_code, 'district') AS piece,
       prefix_of('GB-SW1A 1AA'::postal_code, 'district') AS level,
       lower_bound('GB-SW1A') AS level_starts_at,
       outcode('GB-SW1A 1AA') AS same_as_outcode;

-- a part the code does not have is NULL; so is anything given NULL
SELECT part('GB-SW1A'::postal_code, 'sector') IS NULL AS no_sector,
       part('GB-SW1A'::postal_code, 'walk') IS NULL AS no_walk,
       prefix_of('GB-SW1A'::postal_code, 'walk') IS NULL AS no_walk_prefix,
       part('US-90210'::postal_code, 'plus4') IS NULL AS no_plus4,
       part(NULL::postal_code, 'area') IS NULL AS null_code,
       part('GB-SW1A 1AA'::postal_code, NULL) IS NULL AS null_name,
       parts(NULL::postal_code) IS NULL AS null_parts;

-- group and filter by a level
CREATE TEMP TABLE addr (id serial, pc postal_code);
INSERT INTO addr (pc) VALUES ('GB-SW1A 1AA'), ('GB-SW1A 2AA'), ('GB-SW1A 2BB'), ('GB-SW1V 1AA'),
                              ('GB-SW1A'), ('GB-EC4Y 0HQ'), ('US-90210-1234'), ('US-90210'), ('US-10001');
SELECT prefix_of(pc, 'district') AS district, count(*)
FROM addr WHERE pc::text LIKE 'GB-%' GROUP BY 1 ORDER BY 1;
SELECT pc FROM addr WHERE pc <@ prefix_of('GB-SW1A 1AA'::postal_code, 'sector') ORDER BY pc;
SELECT pc FROM addr WHERE pc <@ prefix_of('GB-SW1A 2AA'::postal_code, 'district') ORDER BY pc;

-- mistakes are errors, and say what there is
SELECT part('GB-SW1A 1AA'::postal_code, 'postcode');
SELECT part('GB-SW1A 1AA'::postal_code, 'District');
SELECT part('FR-75001'::postal_code, 'department');
SELECT parts('FR-75001'::postal_code);
SELECT prefix_of('PL-00-950'::postal_code, 'x');
SELECT part('US-~'::postal_code, 'zip5');

-- the UK type has the same four parts, read from its own fields (and unlike postal_code's they are IMMUTABLE)
SELECT pc, part(pc, 'area') AS area, part(pc, 'district') AS district, part(pc, 'sector') AS sector, part(pc, 'walk') AS walk
FROM (VALUES ('SW1A 1AA'::postcode), ('EC4Y 0HQ'), ('M1 1AA'), ('BX5 5AT'), ('GY1 1AA'), ('GX11 1AA')) v(pc);
SELECT parts('SW1A 1AA'::postcode), parts('M1 1AA'::postcode);
SELECT pc, prefix_of(pc, 'area') AS area, prefix_of(pc, 'district') AS district,
       prefix_of(pc, 'sector') AS sector, prefix_of(pc, 'walk') AS walk
FROM (VALUES ('SW1A 1AA'::postcode), ('EC4Y 0HQ'), ('M1 1AA')) v(pc);

-- ... which is what to_char's letters were: every one of them is now spelled with a name
SELECT bool_and(to_char(pc, 'A') = part(pc, 'area')
            AND to_char(pc, 'D') = part(pc, 'district')
            AND to_char(pc, 'S') = part(pc, 'sector')
            AND to_char(pc, 'W') = part(pc, 'walk')
            AND to_char(pc, 'AD') = prefix_of(pc, 'district')
            AND to_char(pc, 'AD S') = prefix_of(pc, 'sector')
            AND to_char(pc, 'AD SW') = prefix_of(pc, 'walk')
            AND pc::text = prefix_of(pc, 'walk')) AS to_char_replaced
FROM (VALUES ('SW1A 1AA'::postcode), ('EC4Y 0HQ'), ('M1 1AA'), ('BX5 5AT'), ('GY1 1AA'), ('GX11 1AA'),
             ('W1A 0AX'), ('B33 8TH'), ('CR2 6XH'), ('DN55 1PT'), ('LS24 8AA'), ('ZE1 0AA')) v(pc);

-- ... and it agrees with postal_code, where both can hold the code
SELECT bool_and(part(pc, n) = part(('GB-' || pc::text)::postal_code, n)
            AND parts(pc) = parts(('GB-' || pc::text)::postal_code)) AS same_as_postal_code
FROM (VALUES ('SW1A 1AA'::postcode), ('EC4Y 0HQ'), ('M1 1AA'), ('BX5 5AT'), ('GY1 1AA'), ('GX11 1AA'), ('LS24 8AA')) v(pc),
     (VALUES ('area'), ('district'), ('sector'), ('walk')) names(n);

-- find the postcodes in the same sector or district: the % operator takes the text prefix_of() gives
SELECT pc FROM (VALUES ('SW1A 1AA'::postcode), ('SW1A 1AB'), ('SW1A 2AA'), ('SW1V 1AA'), ('EC4Y 0HQ')) v(pc)
WHERE pc % prefix_of('SW1A 1AA'::postcode, 'sector') ORDER BY pc;
SELECT pc FROM (VALUES ('SW1A 1AA'::postcode), ('SW1A 1AB'), ('SW1A 2AA'), ('SW1V 1AA'), ('EC4Y 0HQ')) v(pc)
WHERE pc % prefix_of('SW1A 1AA'::postcode, 'district') ORDER BY pc;
SELECT prefix_of(pc, 'district') AS district, count(*)
FROM (VALUES ('SW1A 1AA'::postcode), ('SW1A 2AA'), ('SW1V 1AA'), ('EC4Y 0HQ')) v(pc) GROUP BY 1 ORDER BY 1;

-- they can be indexed, which postal_code's cannot
CREATE TEMP TABLE uk (pc postcode);
INSERT INTO uk VALUES ('SW1A 1AA'), ('SW1A 2AA'), ('EC4Y 0HQ');
CREATE INDEX uk_area ON uk (part(pc, 'area'));
SELECT part(pc, 'area') AS area, count(*) FROM uk GROUP BY 1 ORDER BY 1;

-- a value that is not a valid postcode has no parts; a wrong part name is an error that says what there is
SELECT part(range_upper('GX'), 'area') IS NULL AS bound_has_no_parts, to_char(range_upper('GX'), 'AD SW') AS what_to_char_gives;
SELECT part('SW1A 1AA'::postcode, 'postcode');
SELECT part(NULL::postcode, 'area') IS NULL AS null_in_null_out;

-- two types now have these functions, so a bare string literal cannot say which: cast it (a column needs nothing)
SELECT part('SW1A 1AA', 'area');
SELECT part('SW1A 1AA'::postcode, 'area'), part('GB-SW1A 1AA'::postal_code, 'area');

-- what each country's parts are
SELECT iso2, format, ord, name FROM postal_code_parts
WHERE iso2 IN ('GB', 'GG', 'US', 'CA', 'IE', 'BR', 'FR', 'PL') ORDER BY iso2, ord;

-- the built-in patterns with real structure have parts; the ones that are one number have none
SELECT count(DISTINCT iso2) AS countries_with_pattern_parts FROM postal_code_parts WHERE format = 'pattern v1';
SELECT iso2, string_agg(name, ', ' ORDER BY ord) AS parts FROM postal_code_parts
WHERE format = 'pattern v1' GROUP BY iso2 ORDER BY iso2;
SELECT code, parts(code) FROM (VALUES ('PL-00-950'::postal_code), ('JP-100-0001'), ('CL-833-0000'), ('ES-28001'), ('TR-34000'),
       ('KY-1-1100'), ('MT-VLT 1117'), ('MT-VLT'), ('NL-1012 AB'), ('NL-1012'), ('PT-1000-001'), ('PT-1000'),
       ('AR-B1832GMR'), ('AR-B1832'), ('AR-1832'), ('CO-630001-025'), ('CO-630001'), ('TW-100-12'), ('BM-HM 12'),
       ('PR-00601-1234'), ('GU-96910'), ('VI-00802')) v(code);
SELECT prefix_of('ES-28001'::postal_code, 'province') = postal_prefix('ES-28') AS spain_province_level,
       prefix_of('NL-1012 AB'::postal_code, 'digits') = postal_prefix('NL-1012') AS dutch_digits_level,
       prefix_of('PL-00-950'::postal_code, 'prefix') = postal_prefix('PL-00') AS polish_prefix_level;
-- naming never changed which codes a built-in language denotes ...
SELECT count(*) AS builtin_languages_that_differ_from_their_source
FROM postal_code_languages l WHERE builtin AND NOT postal_code_same_codes(postal_code_pattern_check(l.source), l.pattern);

-- a pattern of your own names its parts: a regular expression with (?<name>...)
SELECT add_country_template('QP', '/(?<major>\d{2})-(?<minor>\d{3})(-(?<extra>[A-C]))?/');
SELECT parts('QP-12-345'::postal_code), parts('QP-12-345-B'::postal_code);
SELECT part('QP-12-345-B'::postal_code, 'extra') AS extra, part('QP-12-345'::postal_code, 'extra') IS NULL AS no_extra;
SELECT prefix_of('QP-12-345-B'::postal_code, 'minor') = postal_prefix('QP-12-345') AS minor_level;
SELECT ord, name FROM postal_code_parts WHERE iso2 = 'QP' ORDER BY ord;

-- nesting: the outer part includes its children; an alternation: only one branch's part is present
SELECT add_country_template('QR', '/(?<code>(?<first>\d{2})(?<second>\d{2})?)|(?<word>[A-C]{3})/');
SELECT parts('QR-1234'::postal_code), parts('QR-12'::postal_code), parts('QR-ABC'::postal_code);

-- the names are labels: the same codes written or named differently relabel the language, they do not make a new version
SELECT add_country_template('QP', '/(?<a>\d{2})-(?<b>\d{3})(-(?<c>[A-C]))?/');
SELECT version, source FROM postal_code_languages WHERE iso2 = 'QP' ORDER BY version;
SELECT parts('QP-12-345-B'::postal_code) AS relabelled, 'QP-12-345-B'::postal_code = 'QP-12-345-B'::postal_code AS same_value;
-- ... and they can go altogether, even though the pattern is written quite differently
SELECT add_country_template('QP', '/\d{2}-\d{3}(-[A-C])?/');
SELECT version, source FROM postal_code_languages WHERE iso2 = 'QP' ORDER BY version;
SELECT count(*) AS parts_left FROM postal_code_parts WHERE iso2 = 'QP';
SELECT part('QP-12-345'::postal_code, 'a');
SELECT add_country_template('QP', '/(?<major>\d{2})-(?<minor>\d{3})(-(?<extra>[A-C]))?/');
SELECT version, source FROM postal_code_languages WHERE iso2 = 'QP' ORDER BY version;
-- ... but a different set of codes is a new language
SELECT add_country_template('QP', '/(?<a>\d{2})-(?<b>\d{4})/');
SELECT version, source FROM postal_code_languages WHERE iso2 = 'QP' ORDER BY version;
SELECT 'QP-12-3456'::postal_code = 'QP-12-3456'::postal_code AS version2_works, parts('QP-12-3456'::postal_code);
-- a built-in language is never edited, and the same codes never make a new version of it
SELECT add_country_template('DK', '/(?<a>\d{4})/');
SELECT add_country_template('PL', 'NN-NNN');          -- exactly what PL was made from: nothing to do, nothing said
SELECT add_country_template('PL', '/\d{2}-\d{3}/');
SELECT iso2, version, builtin FROM postal_code_languages WHERE iso2 IN ('DK', 'PL') ORDER BY iso2, version;
SELECT add_country_template('DK', '/(?<a>\d{5})/');
SELECT iso2, version, builtin FROM postal_code_languages WHERE iso2 = 'DK' ORDER BY version;

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
SELECT parts('QS-SW1A 1AA'::postal_code);
SELECT add_country_template('QS', '/(?<a>\d{2})(?<b>\d{1,2})/');
SELECT parts('QS-1234'::postal_code), parts('QS-123'::postal_code);

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
