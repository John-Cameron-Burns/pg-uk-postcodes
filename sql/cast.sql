-- Real CREATE CAST entries, on top of the implicit ::text/::postcode I/O
-- fallback every type already gets for free with no cast registered at
-- all. Behaviour is unchanged either direction -- these tests are mostly
-- about confirming the *catalog* entries exist and agree with the old
-- ::syntax, plus the one thing only a real cast fixes: ALTER COLUMN
-- TYPE's automatic dependent-index rewrite.

-- postcode <-> text: new named functions agree with the old :: fallback
SELECT postcode_to_text('SW1A 1AA'::postcode) = 'SW1A 1AA'::postcode::text;
SELECT text_to_postcode('SW1A 1AA') = 'SW1A 1AA'::postcode;
SELECT postcode_to_text(range_lower('BA')) IS NULL;

-- and the cast syntax itself now goes through a real pg_cast, not just
-- the implicit I/O fallback
SELECT CAST('SW1A 1AA'::postcode AS text) = 'SW1A 1AA';
SELECT CAST('SW1A 1AA' AS postcode) = 'SW1A 1AA'::postcode;

-- ASSIGNMENT-level: usable in INSERT/UPDATE target position and function
-- argument coercion without an explicit :: -- a real registered cast,
-- not just literal-constant resolution (which would "work" regardless,
-- cast or no cast, since an unknown-type literal always resolves via
-- the target's own input function)
CREATE TEMP TABLE cast_target (code postcode);
INSERT INTO cast_target (code) SELECT 'SW1A 1AA'::text; -- text value, not a literal -- needs the real cast
SELECT code::text FROM cast_target;

-- explicit cast still raises on genuinely invalid input -- unchanged
-- strict behaviour, same as ::postcode/postcode_in always had; text_to_postcode() isn't
-- the lenient topostcode()
SELECT text_to_postcode('not a postcode');
SELECT CAST('not a postcode' AS postcode);

-- dps <-> text, same pattern
SELECT dps_to_text('1A'::dps) = '1A'::dps::text;
SELECT text_to_dps('1A') = '1A'::dps;
SELECT CAST('1A'::dps AS text) = '1A';
SELECT CAST('1A' AS dps) = '1A'::dps;
SELECT text_to_dps('!!');

-- The actual motivating case, reproducing os_built_address_loader's real
-- bug exactly: a functional index using postcode::text (e.g.
-- split_part, the pre-1.3.1 indexing approach some fleet tables still
-- use) survives the round trip through ALTER COLUMN TYPE ... TYPE text
-- ... TYPE postcode (widen for a safe bulk load, then narrow back) now
-- that a real cast exists, without the manual DROP INDEX / CREATE INDEX
-- dance previously required. The *narrow* direction is what actually
-- used to fail -- `function split_part(postcode, text, integer) does
-- not exist`, since re-resolving the stored index expression against
-- the new postcode-typed column had no real cast to insert for
-- split_part's text parameter. The widen direction already worked
-- before this version (postcode::text degrades to text::text trivially
-- once the column is already text) -- included for completeness, not
-- because it was ever broken.
CREATE TEMP TABLE idx_survives (id serial primary key, code postcode);
INSERT INTO idx_survives (code) VALUES ('SW1A 1AA'), ('BA1 1AZ'), ('M1 1AE');
CREATE INDEX idx_survives_split_part_idx ON idx_survives (split_part(code::text, ' ', 1));
ALTER TABLE idx_survives ALTER COLUMN code TYPE text USING code::text;    -- widen
ALTER TABLE idx_survives ALTER COLUMN code TYPE postcode USING code::postcode; -- narrow -- this used to fail
SELECT regexp_replace(indexdef, 'pg_temp_[0-9]+\.', 'pg_temp.') AS indexdef FROM pg_indexes WHERE tablename = 'idx_survives';
SELECT code::text, split_part(code::text, ' ', 1) FROM idx_survives ORDER BY code;
