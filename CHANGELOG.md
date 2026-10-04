# Changes

## 2.0.0

**Upgrading from 1.3.x:** `ALTER EXTENSION postcode UPDATE;`. The `postcode` and `dps` types, their
functions, operators and operator classes are unchanged, and stored values are untouched. 2.0.0 only adds.

**New: `postal_code`**, a 64-bit type for the postal codes of any country (see `README.md`).

* Written `CC-code` as the UPU recommends: `US-90210`, `GB-SW1A 1AA`, `FR-75008`. Values sort by country
  in ISO 3166-1 order, then by their own code; a coarser value sorts just before the finer ones that
  extend it (an outcode, a ZIP5 before its ZIP+4s).
* Formats for 194 of the 250 ISO countries and territories; the other 56 have no postal codes
  (`SELECT * FROM postal_code_world`). Eight formats are compiled (US, CA, FR, BR, CZ, LU, GB, IE); the
  rest are *templates*, and a new country is added with SQL: `add_country_template('PL', 'NN-NNN')`.
* Prefix matching as a btree range scan: `postal_prefix()`, `to_postal_prefix()`, `lower_bound()`,
  `upper_bound()`, the `postal_code_range` type, and the `%` / `!%` operators. `outcode()` / `district()`.
* `is_valid()` and the NULL-returning `to_postal_code()` for loading dirty feeds. Input tolerates the
  spellings real data uses (other scripts' digits, Unicode dashes and spaces, missing hyphens, the
  country's own letters in front) and nothing else.
* A column can be locked to a country: `pc postal_code('US')`.
* Country assignments are data (`postal_code_country_formats`, `add_country_format()`,
  `remove_country_format()`), with shipped and user assignments kept apart so that a dump carries yours.

**Compatibility:** PostgreSQL 14 or later. Regression-tested on PostgreSQL 17; `.github/workflows/test.yml`
runs the suite on 14 to 18.

**Things to know**

* Restoring a dump that contains `postal_code` values for countries *you* assigned needs the extension's
  own configuration tables loaded first; `pg_restore` loads data in name order. A reordered restore list
  is documented in the README. Values for the built-in countries restore with no special handling.
* `postal_code_in` and the two-argument constructor are `STABLE`, not `IMMUTABLE`, because they depend on
  the country table, so they cannot be used in an index expression. Indexing a `postal_code` column is
  unaffected.
* A template's slot is permanent once a value has been written under it; to change a country's format,
  assign it a new template. See `README.md`.
* Validated on 117 million OpenStreetMap postcodes, 1.8 million GeoNames codes and 24,000 Companies House
  addresses; `VALIDATION.md` has the method, results, and the known gaps.

## 1.3.5 and earlier

See the upstream project, and this fork's git history.
