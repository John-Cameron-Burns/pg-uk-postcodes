-- Validates the postal_code type against a large sample of real postcodes from OpenStreetMap.
--
-- Inputs: table osm_raw(files text, src text, ac text, value text, n bigint), loaded from the CSVs
-- tools/osm_extract.py writes (files = the extract's ISO codes, src = addr|area, ac = the feature's
-- addr:country tag or '', value, n). tools/osm_run.py downloads Geofabrik's per-country extracts and
-- runs the extractor over them.
--
--   psql -f tools/osm_validate.sql dbname        (the extension must be installed; unassigned
--                                                  countries simply parse to NULL)
--
-- What it checks, and what it prints:
--   1. parse rate, overall and per country, for addr:postcode tags and for postal_code boundaries
--      (the latter are mapped postcode areas, so they are the more reliable values);
--   2. every parsed value round-trips through text, through COPY ... (FORMAT binary), and is
--      idempotent under outcode(); is_valid() agrees with to_postal_code();
--   3. sort order of the type matches text order within each country (GB sorts by its area table,
--      so it is reported separately);
--   4. prefix ranges: every distinct prefix of every parsed value counted by postal_prefix()
--      against a plain text prefix count -- they must agree exactly;
--   5. what is rejected, by shape, per country, to separate noise (phone codes, 00000, names) from
--      a real format the templates do not hold.
\set ON_ERROR_STOP off
\pset pager off
\timing off

DROP TABLE IF EXISTS osm_val;
CREATE TABLE osm_val AS
SELECT cc, src, value, sum(n) AS n, to_postal_code(value, cc) AS pc
FROM (
   SELECT CASE WHEN upper(ac) = 'UK' THEN 'GB'
               WHEN ac ~ '^[A-Za-z]{2}$' THEN upper(ac)
               WHEN files !~ ',' THEN files END AS cc,
          src, value, n
   FROM osm_raw
) x
WHERE cc IS NOT NULL
GROUP BY cc, src, value;
CREATE INDEX ON osm_val (cc);
ANALYZE osm_val;

\echo '=== 0. what was loaded'
SELECT (SELECT sum(n) FROM osm_raw) AS values_total,
       (SELECT sum(n) FROM osm_raw WHERE files ~ ',' AND ac !~ '^[A-Za-z]{2}$') AS unattributed_multi_country,
       (SELECT count(DISTINCT cc) FROM osm_val) AS countries,
       (SELECT count(*) FROM osm_val) AS distinct_values;

\echo '=== 1. parse rate'
SELECT src, sum(n) AS values, sum(n) FILTER (WHERE pc IS NOT NULL) AS parsed,
       round(100.0 * sum(n) FILTER (WHERE pc IS NOT NULL) / sum(n), 2) AS pct_of_values,
       count(*) AS distinct_values, count(*) FILTER (WHERE pc IS NOT NULL) AS distinct_parsed,
       round(100.0 * count(*) FILTER (WHERE pc IS NOT NULL) / count(*), 2) AS pct_of_distinct
FROM osm_val GROUP BY src ORDER BY src;

DROP TABLE IF EXISTS osm_country;
CREATE TABLE osm_country AS
SELECT v.cc, w.format, w.basis, sum(v.n) AS n, count(*) AS distinct_values,
       sum(v.n) FILTER (WHERE v.pc IS NOT NULL) AS parsed,
       round(100.0 * sum(v.n) FILTER (WHERE v.pc IS NOT NULL) / sum(v.n), 1) AS pct,
       round(100.0 * sum(v.n) FILTER (WHERE v.pc IS NOT NULL AND v.src = 'area') / nullif(sum(v.n) FILTER (WHERE v.src = 'area'), 0), 1) AS pct_areas,
       sum(v.n) FILTER (WHERE v.src = 'area') AS area_values
FROM osm_val v LEFT JOIN postal_code_world w ON w.iso2 = v.cc
GROUP BY v.cc, w.format, w.basis;

\echo '=== 1a. countries with values but no format (is the "no postal codes" call right?)'
SELECT cc, basis, n AS values, distinct_values FROM osm_country WHERE format IS NULL ORDER BY n DESC LIMIT 40;

\echo '=== 1b. lowest parse rates, countries with at least 200 values'
SELECT cc, format, basis, n AS values, pct, pct_areas, area_values FROM osm_country WHERE format IS NOT NULL AND n >= 200 ORDER BY pct, cc LIMIT 45;

\echo '=== 1c. postcode areas (postal_code=*), lowest parse rates'
SELECT cc, format, area_values, pct_areas FROM osm_country WHERE area_values >= 20 ORDER BY pct_areas, cc LIMIT 30;

\echo '=== 2. round trips (all parsed distinct values)'
CREATE TEMP TABLE parsed AS SELECT DISTINCT cc, pc FROM osm_val WHERE pc IS NOT NULL;
SELECT count(*) AS distinct_codes,
       count(*) FILTER (WHERE to_postal_code(pc::text) IS DISTINCT FROM pc) AS text_roundtrip_fail,
       count(*) FILTER (WHERE country(pc) <> cc) AS country_mismatch,
       count(*) FILTER (WHERE outcode(outcode(pc)) IS DISTINCT FROM outcode(pc)) AS outcode_not_idempotent,
       count(*) FILTER (WHERE outcode(pc) IS NOT NULL AND NOT (outcode(pc) <= pc)) AS outcode_after_value,
       count(*) FILTER (WHERE NOT is_valid(pc::text)) AS is_valid_disagrees
FROM parsed;
COPY (SELECT pc FROM parsed) TO '/tmp/osm_pc.bin' (FORMAT binary);
DROP TABLE IF EXISTS osm_back; CREATE TEMP TABLE osm_back (pc postal_code);
COPY osm_back FROM '/tmp/osm_pc.bin' (FORMAT binary);
SELECT (SELECT count(*) FROM osm_back) AS binary_rows,
       (SELECT count(*) FROM (SELECT pc FROM parsed EXCEPT SELECT pc FROM osm_back) a) AS lost_in_binary,
       (SELECT count(*) FROM (SELECT pc FROM osm_back EXCEPT SELECT pc FROM parsed) b) AS invented_in_binary;

\echo '=== 3. type order == text order, per country (value counts where they differ)'
WITH r AS (
   SELECT cc, pc,
          row_number() OVER (PARTITION BY cc ORDER BY pc) AS a,
          row_number() OVER (PARTITION BY cc ORDER BY pc::text COLLATE "C") AS b
   FROM parsed)
SELECT cc, count(*) AS codes, count(*) FILTER (WHERE a <> b) AS out_of_order
FROM r GROUP BY cc HAVING count(*) FILTER (WHERE a <> b) > 0 ORDER BY 3 DESC LIMIT 30;

\echo '=== 4. prefix ranges vs text prefix counts (must agree exactly)'
CREATE TEMP TABLE pt AS SELECT cc, pc, substr(pc::text, 4) AS nat FROM parsed;
CREATE INDEX ON pt (pc);
ANALYZE pt;     -- temp tables are never analysed by autovacuum; without this the join below is hopeless
-- The UK format reads GB-AB1 as district 1 and GB-B as area B, not as "every code whose text starts with
-- that" (AB1 is not a district at all; AB10..AB19 are), so a plain text prefix is the wrong oracle for it.
-- For countries on that format the check is structural: every complete outcode (counted by outcode()),
-- and every fragment containing a space (sector and unit level), where text and structure agree.
CREATE TEMP TABLE ukfmt AS SELECT iso2 FROM postal_code_world WHERE format = 'GB';
-- (a fragment's trailing space is insignificant -- text is tidied -- so prefixes ending in a space are not distinct fragments)
CREATE TEMP TABLE pref AS
SELECT DISTINCT cc, left(nat, n) AS frag FROM pt, generate_series(1, 6) n
WHERE length(nat) >= n AND left(nat, n) !~ ' $' AND (cc NOT IN (SELECT iso2 FROM ukfmt) OR left(nat, n) ~ ' ')
UNION
SELECT DISTINCT cc, substr(outcode(pc)::text, 4) FROM parsed WHERE cc IN (SELECT iso2 FROM ukfmt) AND outcode(pc) IS NOT NULL;
SELECT count(*) AS prefixes FROM pref;
-- a fragment the parser does not take gives NULL (to_postal_prefix), and is counted, not fatal
CREATE TEMP TABLE bounds AS
SELECT cc, frag, lower(r) AS lo, upper(r) AS hi
FROM (SELECT cc, frag, to_postal_prefix(cc || '-' || frag) AS r FROM pref) x;
SELECT cc, count(*) AS fragments_not_accepted, min(frag) AS example FROM bounds WHERE lo IS NULL GROUP BY cc ORDER BY 2 DESC LIMIT 20;
DELETE FROM bounds WHERE lo IS NULL;
CREATE INDEX ON bounds (cc);
ANALYZE bounds;
CREATE TEMP TABLE by_range AS
SELECT b.cc, b.frag, count(t.pc) AS c FROM bounds b LEFT JOIN pt t ON t.pc >= b.lo AND t.pc < b.hi GROUP BY b.cc, b.frag;   -- the range alone is selective: countries lie end to end in the value space
CREATE TEMP TABLE by_text AS
SELECT cc, left(nat, n) AS frag, count(*) AS c FROM pt, generate_series(1, 6) n
WHERE length(nat) >= n AND left(nat, n) !~ ' $' AND (cc NOT IN (SELECT iso2 FROM ukfmt) OR left(nat, n) ~ ' ')
GROUP BY 1, 2
UNION ALL
SELECT cc, substr(outcode(pc)::text, 4), count(*) FROM parsed WHERE cc IN (SELECT iso2 FROM ukfmt) AND outcode(pc) IS NOT NULL GROUP BY 1, 2;
SELECT count(*) AS prefixes_checked, count(*) FILTER (WHERE r.c IS DISTINCT FROM x.c) AS mismatches
FROM by_range r JOIN by_text x USING (cc, frag);
SELECT cc, count(*) AS mismatching_prefixes, min(frag) AS example FROM by_range r JOIN by_text x USING (cc, frag) WHERE r.c IS DISTINCT FROM x.c GROUP BY cc ORDER BY 2 DESC;
SELECT cc, '[' || frag || ']' AS frag, r.c AS by_range, x.c AS by_text FROM by_range r JOIN by_text x USING (cc, frag)
WHERE r.c IS DISTINCT FROM x.c ORDER BY cc, frag LIMIT 25;

\echo '=== 5. what is rejected, by shape (top shapes per country with >= 20 rejected values)'
CREATE TEMP TABLE rej AS
SELECT cc, value, n, regexp_replace(regexp_replace(upper(value), '[A-Z]', 'A', 'g'), '[0-9]', 'N', 'g') AS shape
FROM osm_val WHERE pc IS NULL AND cc IN (SELECT iso2 FROM postal_code_world WHERE format IS NOT NULL);
SELECT cc, sum(n) AS rejected, round(100.0 * sum(n) / (SELECT sum(n) FROM osm_val v WHERE v.cc = rej.cc), 1) AS pct_of_country,
       (SELECT string_agg(shape || ' x' || c || ' (' || ex || ')', '  |  ' ORDER BY c DESC)
        FROM (SELECT shape, sum(n) AS c, min(value) AS ex FROM rej r2 WHERE r2.cc = rej.cc GROUP BY shape ORDER BY sum(n) DESC LIMIT 5) s) AS top_shapes
FROM rej GROUP BY cc HAVING sum(n) >= 20 ORDER BY sum(n) DESC LIMIT 80;
