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

CREATE VIEW postal_code_parts AS
   SELECT cf.iso2, cf.format_name AS format, n.ord::integer AS ord, n.name
   FROM postal_code_country_formats cf
   JOIN postal_code_format_parts fp ON fp.format_name = cf.format_name
   CROSS JOIN LATERAL unnest(postal_code_pattern_part_names(fp.pattern)) WITH ORDINALITY AS n(name, ord)
   UNION ALL
   SELECT l.iso2, 'pattern v' || l.version, n.ord::integer, n.name
   FROM postal_code_languages l
   CROSS JOIN LATERAL unnest(postal_code_pattern_part_names(l.pattern)) WITH ORDINALITY AS n(name, ord);
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
      AND NEW.created_at = OLD.created_at
      AND NEW.pattern <> OLD.pattern
      AND postal_code_same_codes(NEW.pattern, OLD.pattern) THEN
      RETURN NEW;
   END IF;
   RAISE EXCEPTION 'postal_code_languages rows are permanent: stored postal_code values are decoded with them'
      USING HINT = 'to change a country''s rules, add a new language with add_country_template(); a pattern can only be rewritten in place to one that denotes exactly the same codes, as when naming its parts';
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

   SELECT l.version, l.source, l.pattern, l.builtin INTO cur FROM postal_code_languages l WHERE l.iso2 = norm_cc ORDER BY l.version DESC LIMIT 1;
   IF cur.version IS NOT NULL AND postal_code_same_codes(cur.pattern, re) THEN
      -- the same codes, however written or named: never a new version (which would make different values)
      IF cur.pattern <> re AND cur.source <> spec THEN      -- (the very spec it was made from: nothing to say, as in 2.0.x)
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
