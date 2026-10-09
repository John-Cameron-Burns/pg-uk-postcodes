# Changes

## 2.1.0 (not yet released)

**Upgrading from 2.0.x or 1.3.x:** `ALTER EXTENSION postcode UPDATE;`. Nothing stored changes; 2.1.0 only adds. (A rehearsal on a copy of the production database took 123 ms and left 21 million postcodes bit-for-bit identical.)

**New: named parts.** A pattern can name the parts of a code, `(?<name>...)`, and the parts can be read back:

    SELECT add_country_template('XQ', '/(?<major>\d{2})-(?<minor>\d{3})/');
    SELECT part('XQ-12-345'::postal_code, 'major');               -- 12
    SELECT parts('XQ-12-345'::postal_code);                       -- {"major": "12", "minor": "345"}
    SELECT prefix_of('XQ-12-345'::postal_code, 'major');          -- the range of every code that starts XQ-12

* `part(code, name)` is the piece of text; `prefix_of(code, name)` is everything up to and including it, as a
  `postal_code_range` (indexable, groupable, usable with `<@`). For GB these are the pieces `area`, `district`,
  `sector` and `walk` (as `to_char` names them) and Royal Mail's levels: `part('GB-SW1A 1AA', 'district')` is `1A`;
  `prefix_of(..., 'district')` is the range of `GB-SW1A`.
* `parts(code)` is all of them as `jsonb` (a part the code does not have is null). The view `postal_code_parts`
  lists the parts each country has, in order. GB (and GG, GI, IM, JE), US, CA, IE and BR have parts, and so do 29 of the
  built-in pattern countries (those whose codes really have two kinds of information in them: ES and TR province, KY
  island, MT locality, NL digits and letters, the `base` and `extension` of CO CR IR LB MZ PT SA TW VE, the `zip5` and `plus4`
  of the US territories, the two blocks of JP PL CL BM SO, and AR). The other 142 pattern countries -- one undivided number, or only grouped for
  display, or a code of two lengths, or a single fixed code -- and FR, CZ and LU have none, and `part()` says so.
* **The UK `postcode` type has the same four parts**: `part(pc, 'area')`, `parts(pc)` and `prefix_of(pc, 'district')` (which
  returns the text the `%` operator takes). They are read from the type's own fields, so they are `IMMUTABLE` and can be
  indexed. Every `to_char` letter combination has a replacement; the README has the table.
* Because two types now have `part()`, `parts()` and `prefix_of()`, **a bare string literal is ambiguous**:
  `part('SW1A 1AA', 'area')` is "function part(unknown, unknown) is not unique". Cast it; a column needs nothing.
* A name changes nothing about which codes are valid or how they are stored or ranked, so nothing stored is touched.
* Names are labels, not rules: the same codes written or named differently relabel the current language of a
  country instead of making a new version (which would make different values), and a language's pattern may be
  rewritten in place to any pattern that denotes exactly the same codes (`postal_code_same_codes()`, an exact
  comparison). A different set of codes is still a new version.
* A pattern whose parts could split some code two ways is refused when it is defined, with an example code. Up to
  10 million codes every code is tried; above that an exact analysis of the pattern decides (up to 2,000 positions);
  beyond that a sample is checked and a notice says only some codes were.
* A part must match at least one character and cannot be repeated (`{2}`); lookbehind is refused. Templates cannot
  name parts: write a regular expression.
* `make installcheck` gains a `parts` test; the standalone tests gain the named-parts engine, the ambiguity check,
  the GB parts against the `postcode` layout's own fields (8.3 million codes) and the US, CA, IE and BR parts
  against their encoders.

**Deprecated: `to_char(postcode, text)`.** It keeps working unchanged and will not be removed within 2.x, but it is
not a sensible way to take a code apart (its `A D S W` letters give pieces, not Royal Mail's district and sector).
Use `part()` / `prefix_of()`. The function carries a `COMMENT` saying so; there is no run-time warning, since it is
used in queries and a warning per call would flood logs.

* A change that could surprise: re-adding a pattern that denotes the same codes as a country's current language,
  written differently, no longer makes a new version (which made different values). For your own language it relabels it;
  for a built-in language it says so in a NOTICE and keeps it. The very spec a language was made from is still silent, as in 2.0.x.
* The error for a statement that is not `(?: )` or `(?<name> )` grouping now mentions named parts.

## 2.0.1

**Upgrading from 2.0.0 or 1.3.x:** `ALTER EXTENSION postcode UPDATE;`

* **`is_valid(text)` and `is_valid(text, text)` are replaced by one function,
  `is_valid_postal_code(postcode text, cc text DEFAULT NULL)`.** Same arguments and results; the country is
  now optional. Callers of `is_valid(...)` must change. A bare `is_valid` collided with another extension's
  `is_valid(text)` (`gsscode`, installed in the first production database 2.0.0 was tried on) and, wherever the `isn` extension
  is installed, was ambiguous for an untyped literal (`is_valid('US-90210')` failed with "function
  is_valid(unknown) is not unique").
* A database still on 1.3.x upgrades directly to 2.0.1 and never creates `is_valid`; a database on 2.0.0
  has the two old functions dropped and the new one created. Nothing else changes: the data, the types and
  the other functions are as in 2.0.0.

## 2.0.0

**Upgrading from 1.3.x:** `ALTER EXTENSION postcode UPDATE;`. The `postcode` and `dps` types, their
functions, operators and operator classes are unchanged, and stored values are untouched. 2.0.0 only adds.

**New: `postal_code`**, a 64-bit type for the postal codes of any country (see `README.md`).

* Written `CC-code` as the UPU recommends: `US-90210`, `GB-SW1A 1AA`, `FR-75008`. Values sort by country
  in ISO 3166-1 order, then by their own code; a coarser value sorts just before the finer ones that
  extend it (an outcode, a ZIP5 before its ZIP+4s).
* Formats for 194 of the 250 ISO countries and territories; the other 56 have no postal codes
  (`SELECT * FROM postal_code_world`). Eight formats are compiled (US, CA, FR, BR, CZ, LU, GB, IE); the
  rest are *patterns* -- a template or a bounded regular expression that defines the whole set of a country's codes (a code is stored as its rank in that set, so order, validity and prefix ranges are exact) -- and a new country is added with SQL: `add_country_template('PL', 'NN-NNN')` or `add_country_template('NL', '/[1-9]\d{3}( [A-Z]{2})?/')`. Country rules narrower than a code's shape are built in (`NARROWING.md`); the UK format enforces Royal Mail's letter rules.
* Prefix matching as a btree range scan: `postal_prefix()`, `to_postal_prefix()`, `lower_bound()`,
  `upper_bound()`, the `postal_code_range` type, and the `%` / `!%` operators. `outcode()` / `district()`.
* `is_valid()` (renamed `is_valid_postal_code()` in 2.0.1) and the NULL-returning `to_postal_code()` for loading dirty feeds. Input tolerates the
  spellings real data uses (other scripts' digits, Unicode dashes and spaces, missing hyphens, the
  country's own letters in front) and nothing else.
* A column can be locked to a country: `pc postal_code('US')`.
* Country assignments are data (`postal_code_country_formats`, `add_country_format()`,
  `remove_country_format()`), with shipped and user assignments kept apart so that a dump carries yours.

**Compatibility:** PostgreSQL 14 or later. The regression suite passes on 14, 15, 16, 17 and 18 (built from
the release archive); `.github/workflows/test.yml` runs it on all five. One difference: from PostgreSQL 17
the planner turns `pc <@ postal_prefix(...)` into an index scan; on 14 to 16 it is correct but a filter,
and `pc % '...'` or `pc >= lower_bound(...) AND pc < upper_bound(...)` is the indexed form (see `README.md`).

**Things to know**

* Restoring a dump that contains `postal_code` values for countries *you* assigned needs the extension's
  own configuration tables loaded first; `pg_restore` loads data in name order. A reordered restore list
  is documented in the README. Values for the built-in countries restore with no special handling.
* `postal_code_in` and the two-argument constructor are `STABLE`, not `IMMUTABLE`, because they depend on
  the country table, so they cannot be used in an index expression. Indexing a `postal_code` column is
  unaffected.
* A pattern is permanent once a value has been written under it (each country has 51 versions); to change a
  country's rules, assign it a new pattern. See `README.md`.
* Where separators are dropped from UK outcode or sector text, `SW11` is read as the outcode `SW11`, not
  `SW1 1`; a full postcode is unambiguous.
* Validated on 117 million OpenStreetMap postcodes, 1.8 million GeoNames codes and 24,000 Companies House
  addresses; `VALIDATION.md` has the method, results, and the known gaps.

## 1.3.5 and earlier

See the upstream project, and this fork's git history.
