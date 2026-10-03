# International postcodes: requirements and status

The `postal_code` type, alongside the UK `postcode` type, in the `postcode` extension (2.0.0). Branch `dev/postal_code-international`.

Status as of 2026-10-03. **All six requirements below are implemented**, plus the extras listed after them. The README documents how each is used; `sql/postal_code.sql` / `expected/postal_code.out` are the regression tests.

## Decisions that shape everything

* The type is **`postal_code`** (it was drafted as `intl_postcode`; that name is dead).
* The text form is the UPU form **`CC-postcode`**, CC being the ISO 3166 two-letter code (`US-90210`, `GB-SW1A 1AA`, `FR-75008`). The earlier `CC:` form is gone entirely. The country is always exactly two characters, so the first hyphen is the delimiter even where the national code has hyphens of its own (`US-90210-1234`, `BR-01310-100`).
* A value is 64 bits: country (two 5-bit letters, so it sorts as ISO text) | format (6 bits) | national payload (48 bits). Values from different countries compare by ISO order; within a country, text order. A coarser value sorts immediately before the finer ones that extend it.
* Which format a country uses is a live SQL table, not compiled in.

## The requirements

1. **Separator `CC-` instead of `CC:`** -- done (`91d8a63`).

2. **Constructor taking `(postcode, cc)`; `cc` may be NULL when the postcode carries a `CC-` prefix; an error if they disagree** -- done (`bb04ec2`). `postal_code(postcode, cc)`; the same rules apply to `to_postal_code(postcode, cc)` and `is_valid(postcode, cc)`, which give NULL / false where the strict form raises.

3. **Where there is a distinct outcode and incode (UK, Ireland, Canada, USA), the outcode alone is a valid postcode; where the leading digits are only implicitly an outcode (France), the full code is required** -- done (`91d8a63`). `GB-SW1A`, `IE-D02`, `CA-K1A`, `US-90210` are values. FR, CZ and LU require the whole code. GB (also GG, IM, JE) and IE were added to make this meaningful.

4. **An `outcode()` function, with `district()` as an alias** -- done (`088350c`). Returns the area part as a complete postal_code (`GB-SW1A 1AA` -> `GB-SW1A`; a ZIP+4 -> its ZIP5; Eircode -> routing key). NULL for formats with no distinct outcode and for the end-of-country bound. `IMMUTABLE`, so `CREATE INDEX ON t (outcode(pc))` works.

5. **`upper_bound()` returns a valid postcode where possible; otherwise explore the repercussions** -- done (`b90f9b7`). `upper_bound('GB-LS24')` is the smallest valid value past everything starting with it. At the top of a country there is none, and a range's own "no upper end" would run on into the *next* country, so the bound there is the **end-of-country bound `CC-~`**: a value that sorts after every real postcode of its country and before the next, accepted and shown as text, but not a postcode (`is_valid` rejects it). It is a bound only. Also delivered: `lower_bound()`, the native range type `postal_code_range`, and `postal_prefix()`.

6. **Per-country character and numeric restrictions detected at ingest and exposed as `is_valid()`** -- done (`e361848`). Each format enforces its own rules at input (Canada's excluded letters, the UK area table, Eircode's alphabet, US ZIP+4 `0000`, ...). `is_valid(text)` and `is_valid(postcode, cc)` are exactly `to_postal_code(...) IS NOT NULL`.

## Added beyond the requirements

* **`to_postal_code()`** (`bf34cee`) -- NULL-returning counterparts of the strict constructors, for loading dirty feeds (the `topostcode()` analogue). France accepts and normalises `CEDEX`.
* **Partial match and ranges** (`b90f9b7`) -- every prefix of a code is one contiguous range, so `pc <@ postal_prefix('GB-LS24')` is a btree range scan. A planner support function folds constant fragments, and a trigger invalidates cached plans if a country's format is reassigned.
* **The `%` / `!%` operator** -- the UK type's partial-match operator, ported; lenient for bad fragments, rewritten to a range for index use.
* **Locking a column to a country** -- `pc postal_code('US')`, as PostGIS locks a geometry column to an SRID. Enforced on INSERT/UPDATE/COPY (text and binary), `::postal_code('US')` and `ALTER COLUMN ... TYPE`. `COPY` may use bare national codes; `INSERT` literals need the prefix (a PostgreSQL limit). The `postal_code_columns` view lists the locks.
* **Templated formats** -- `add_country_template('PL', 'NN-NNN')` onboards a country made of fixed-width digit/letter groups with no C and no rebuild. `N` digit, `A` letter, `X` either, separators space and hyphen, one optional `[ ]` tail (the incode). Templates are permanent (a stored value carries its slot as its format), 47 slots, shared by countries with the same shape, 48-bit limit. Validated against about 660,000 real rows from `"@GEONAMES".world` across 18 countries with no rejections.
* **Every country in the world**: 194 of 250 ISO entries have a built-in format (the UAE's holds Abu Dhabi's 5-digit codes and Dubai's Makani location numbers, labelled as such), the other 56 are recorded as having no postal codes (`postal_code_world`). Formats come from the GeoNames data (120 countries, 1.65 million codes, all load but 21 French non-codes) and Wikipedia's list of postal codes; `tools/world_formats.py` generates the table. Countries that write their ISO letters into the code (`VG1110`, `AD500`) use a `CC` template: the letters are optional, checked, and not stored.
* **Countries and formats are data**: the `postal_code_country_formats` view, `add_country_format()`, `remove_country_format()`. Shipped assignments and user assignments are kept apart, so a dump carries everything a user added (templates and country assignments). One caveat: restoring needs those tables loaded before any `postal_code` data (a reordered restore list, documented in the README), because the text input depends on them.
* **Formats implemented in C**: US, CA, FR, BR, CZ, LU, GB (also GG/IM/JE), IE. Anything else with a regular shape is a template.
* **Test suite as part of the package**: the pg_regress test `postal_code`, plus standalone harnesses (`test_postal_code.c`, `test_postal_code_range.c`, `test_postal_code_template.c`) that need no Postgres.

## Planned or open

* **Restore ordering.** `pg_restore` loads table data in name order, so user data can be read before the assignments it needs. A reordered restore list works (README); making it automatic would need a dependency pg_dump understands, which the extension mechanism doesn't offer.
* **Reviewing the Wikipedia-only formats.** About 70 countries have no GeoNames rows, so their format is Wikipedia's alone (basis `Wikipedia` in `postal_code_world`); a few (Egypt, Myanmar, Vietnam, Israel) accept two lengths because the sources disagree. They need checking against real data when it is available.
* **Fixed digits in a template** (French Guiana's `973NN`, Monaco's `980NN`) are not expressible, so those territories accept a little more than is really used.
* **Validating `cc` against the ISO 3166 list** when a country is assigned, to catch typos and retired codes.
* **Sharjah's PCS, and the UAE's emirates generally.** The UAE has several schemes and AE holds one format (`NNNNN[ NNNNN]`: Abu Dhabi's 5-digit codes and Dubai's Makani numbers), so Sharjah's PCS is not modelled. Adding it needs its layout; the type is keyed by country, so per-emirate formats would be a larger change.
* **Template limits**: no excluded symbols or reserved values, no variable-length codes other than the one optional tail. A country needing those takes a compiled encoder, or a template that accepts slightly too much.
* **Ranges over historical formats**: range bounds cover a country's *current* format only, since the format bits sit between country and payload.
* **A GiST `subtype_diff`** for `postal_code_range`, for GiST-indexed range queries.
* **Releasing**: merge `dev/postal_code-international` to `main` (or open a PR), and test the `1.3.5 -> 2.0.0` upgrade path on a database that already has `postcode` data.
