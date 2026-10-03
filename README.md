Postcode 1.3
============
UK postcode encoded in 32 bits and optimised for indexing and partial matches


Coverage
--------
Supports all 127 postcode areas. The crown dependencies GY, JE and IM and
Gibraltar's GX area are
included plus two non-geographic areas BX and BF.

The type should support all current and future codes with the sole exception
of the atypical code GIR 0AA, which Royal Mail nolonger includes within the
postcode address file. In the unlikely event further postcode areas are added
the type is extensible to a maximum of 255 areas (see areas.h)


Parsing
-------
Text input must match one of the above areas followed by a correctly specified
district, sector and walk. Although the type enforces entry of a code with the
correct components, confirming a code is allocated for use requires an external
data source such as [Code-Point Open](http://www.ordnancesurvey.co.uk)

The text parser is relatively tolerant of varied formatting and will correct
for capitalisation and a variable number (or lack of) spaces between the
outward and inward codes.


Rendering
---------
When rendering postcodes to text the default output is upper case with a
single space between the outcode and incode. If an alternative format is
required a to_char() function is provided. The default output is equivalent
to calling to_char(postcode, 'AD SW');

Rendering never fails as of 1.3.3. A field that isn't a valid, complete
value -- which in practice means a range_lower()/range_upper() boundary
from a fragment short enough to leave something genuinely unfillable, or
truly corrupted data -- renders as `?` for whichever specific character
isn't available, rather than raising. A normal, complete postcode is
entirely unaffected (including the common case of a one-digit district,
e.g. `'SW1 1AA'`, which was always valid and still renders exactly as
entered).


Partial matching
----------------
For partial match queries using the % operator any potential ambiguity is
resolved by allocating the maximum number of digits to the district unless an
explicit space is placed between the district and sector.

For example % 'LS24' returns all postcodes in district LS24. To return all
codes in sector 4 of LS2 use % 'LS2 4'.

Neither or both characters of the walk must be entered. A partial search
including them is functionally equivalent to the equality = operator.

1.0 through 1.2, % was a plain function call, index-accelerated for
neither a constant nor a variable fragment. 1.3.0 registered it under
btree strategy 3 (the "equality" slot) to try to change that, but this
produced wrong results whenever an index existed on the column (upstream
issue #3): btree relies on strategy-3 matches being reflexive/
interchangeable, which a partial match isn't -- two different postcodes
can both match the same fragment without being equal to each other. 1.3.1
removed that registration, restoring correctness but leaving % unindexed
again either way, same as 1.0-1.2. Since 1.3.3, % gets an index-assisted
plan for a *constant* fragment (the common case: `code % 'LS24'`, not
`code % some_column`) via a planner support function that rewrites the
call into the range_lower()/range_upper() form below at plan time --
`EXPLAIN` will show a normal index scan, `code`'s own value is what's
compared, no opfamily trickery, none of 1.3.0's soundness bug. A
non-constant fragment still runs the plain, always-correct, unindexed
function, exactly as it always has. See Indexing below for the range
form itself, which is still the thing to reach for directly if you want
that plan guaranteed rather than inferred.


Indexing
--------
Standard B-tree operators are supported. The sort order is consistent with
that of the type rendered to text format using the C locale.

For an indexed partial match, use range_lower()/range_upper() instead of
%: they express a fragment as a genuine half-open range, using the
ordinary (and ordinarily correct) </>= operators for full index support:

    SELECT * FROM addresses
    WHERE postcode >= range_lower('LS24') AND postcode < range_upper('LS24');

Unlike %/!%, range_lower()/range_upper() raise an error on an invalid
fragment rather than silently returning a value -- they're meant to be
called with a literal, known-good fragment when constructing a query, not
with arbitrary/untrusted input.

Since 1.3.3, both bounds are real, valid, directly-renderable postcodes,
not raw internal values -- `range_lower('LS1')` is `'LS1 0AA'`,
`range_upper('LS1')` is `'LS10 0AA'` (the lowest real postcode of
whichever fragment immediately follows LS1 -- not, perhaps
counter-intuitively, `'LS2 ...'`: LS1 and LS10 share the same first
district digit and sort adjacently, LS2 doesn't come until every LS1x
district is exhausted -- the type's sort order matches the text form's
own left-to-right character order, so this is the same ordering
`ORDER BY postcode` or a plain text comparison would already give you).
This is why `EXPLAIN`'s output for the % rewrite above reads as real
postcodes too. The interval is always half-open and exclusive at the top
-- `range_upper(X)` is never itself included by a `< range_upper(X)`
comparison -- so it being a real postcode (specifically, the real lower
bound of whatever comes next) is exactly the tiling property that makes
adjacent fragments' ranges meet with no gap and no overlap, not a loose
end.

A B-tree index for the encoded type will be approximately 25% smaller than
an equivalent index on a column of type text. This may give a performance
advantage where the index can therefore be held entirely within memory.

Since 1.3.4, `<`/`<=`/`>`/`>=` (both `postcode` and `dps`) carry real
selectivity estimators (PostgreSQL's own standard `scalarltsel`/
`scalarlesel`/`scalargtsel`/`scalargesel` and join counterparts, the
same ones `int4`/`text`/`date` use for these operators) -- previously
unset entirely, which meant the planner had no way to use `ANALYZE`'s
own column statistics for a range predicate at all, regardless of how
accurate or fresh those statistics were, and would fall back to a fixed
default guess. Confirmed live against a real 34.8M-row table with an
existing plain `btree(postcode)` index and fresh statistics: the same
`BETWEEN range_lower/range_upper` query went from a ~39s sequential scan
to a 270ms index scan, no new index, no query change -- purely from the
planner now being able to see the real distribution.


Casting to/from text
---------------------
postcode::text and 'SW1A 1AA'::postcode already work without any of
this -- PostgreSQL falls back to any type's own input/output functions
for the `::` syntax even with no cast registered at all. What that
implicit fallback *doesn't* do is participate in ordinary function-
argument resolution or PostgreSQL's own internal dependent-object
rewriting (notably `ALTER COLUMN ... TYPE`'s automatic index rebuild) --
both need a real `pg_cast` entry to work, which is what this adds.

    postcode AS text   -- IMPLICIT
    text AS postcode   -- ASSIGNMENT
    dps AS text        -- IMPLICIT
    text AS dps        -- ASSIGNMENT

Deliberately asymmetric. `<type> AS text` is IMPLICIT because that's the
direction real call sites actually need auto-coerced -- a functional
index like `split_part(postcode_col::text, ' ', 1)` needs `postcode_col`
to coerce into `split_part`'s text parameter automatically for
PostgreSQL to be able to re-resolve it during `ALTER COLUMN TYPE`'s
index rewrite, and PostgreSQL only ever auto-applies an IMPLICIT cast
for that kind of resolution -- an ASSIGNMENT cast (tried first) is only
auto-applied for INSERT/UPDATE target-column coercion, not general
argument matching, and doesn't actually fix this. `text AS <type>` stays
ASSIGNMENT: nothing in practice needs an arbitrary text value silently
coercing *into* postcode/dps in general expression contexts, and that
direction can raise on invalid input, which is a worse thing to have
fire implicitly than a render that always succeeds for a valid value.

Behaviour is otherwise unchanged either direction -- postcode_to_text()/
dps_to_text() are exactly what ::text already did; text_to_postcode()/
text_to_dps() are exactly what ::postcode/::dps already did, same strict
raise-on-invalid-input as always. topostcode() remains the NULL-safe
alternative for messy/untrusted input, unaffected by any of this.


Delivery point suffixes
-----------------------
For any postcode there is a maximum of 175 delivery points, each of which
is allocated a suffix of the form [1-9][A-Z] with the characters CIKMOV not
used. Suffixes follow the sequence 1A, 1B, 1C through to 9T. Codes 9U-9Z
are for use by applications as defaults where the correct suffix is unknown.

A suitable type (dps) is provided which encodes into one byte all possible
values, including codes 9U-9Z. Parsing is case insensitive but output is
always in upper case.

The type aims to provide strict validation rather than space efficiency,
although some small storage savings can be made compared to char(2) if
careful ordering of columns is made with respect to alignment.


Binary format
-------------
For client applications exchanging results in binary format the functions
declared in binfmt.h can be used for parsing from or rendering to text format


postal_code: any country, not just the UK
------------------------------------------
Since 2.0.0, this same extension also provides `postal_code`, a 64-bit type
covering any country's postal code -- additive alongside `postcode`, not a
replacement for it. Existing `postcode`/`dps` columns, indexes and binary
data are entirely unaffected by installing or upgrading to 2.0.0.

    SELECT 'US-90210-1234'::postal_code;   -- ZIP5 + optional ZIP+4
    SELECT 'CA-K1A 0B1'::postal_code;      -- full FSA+LDU
    SELECT 'CA-T0A'::postal_code;          -- the outcode alone is a complete value
    SELECT 'GB-SW1A'::postal_code;         -- ... as it is for GB and IE
    SELECT postal_code('90210', 'US');     -- two-argument constructor for
                                            -- separate code/country columns,
                                            -- analogous to PostGIS's
                                            -- ST_GeomFromText(wkt, srid)
    SELECT country('US-90210'::postal_code);  -- 'US'

The text form follows the UPU recommendation: the ISO 3166-1 alpha-2 country,
a hyphen, then the national code (`CC-code`). A country code is always
required -- `'90210'::postal_code` raises, there is no implicit default
country. Because the country is always exactly two characters, the *first*
hyphen is the delimiter even when the national code has hyphens of its own
(`US-90210-1234`, `BR-01310-100`). The colon form (`US:90210`) is not accepted.

**Outcode-only is a valid postcode** wherever a country has a distinct
outcode/incode structure -- GB, IE, CA and US (`GB-SW1A`, `IE-A65`,
`CA-K1A`, `US-90210`). Real data backs this: every one of GeoNames' 27,450 GB
rows and all 139 IE rows is outcode-only. Where the leading digits are only
implicitly an outcode (FR, CZ, LU) the full code is required. What is *not*
valid is the in-between: `GB-SW1A 1` (a sector with no unit) is a fragment.

`postal_code(postcode, cc)` takes the country from `cc`, from the postcode's own
`CC-` prefix, or from both -- in which case they must agree:

    SELECT postal_code('90210-1234', 'US');      -- country from cc
    SELECT postal_code('US-90210-1234', NULL);   -- ... or from the prefix; cc may be NULL
    SELECT postal_code('US-90210-1234', 'US');   -- ... or both, if they agree
    SELECT postal_code('US-90210', 'CA');        -- ERROR: cc does not match the prefix
    SELECT postal_code('90210', NULL);           -- ERROR: no country anywhere

A prefix is exactly two letters then a hyphen, which no national format starts
with (Luxembourg's `L-1311` has one letter), so there is no ambiguity. A NULL
postcode gives NULL. `to_postal_code(postcode, cc)` and `is_valid(postcode, cc)` follow
the same rules, giving NULL / false where the strict form would raise.

Countries sort in ISO 3166-1 alpha-2 **text** order unconditionally (`'CA-...'`
always sorts before `'US-...'`), regardless of how any given country's own
national code happens to be packed internally. Within one country, a more
precise variant of the same underlying code -- a ZIP5 vs. that same ZIP5 with
a +4, an outcode vs. a full postcode in it -- interleaves immediately next to
the value it refines, rather than being grouped apart from it by format.

Formats implemented so far:

  * **US** -- 5-digit ZIP, with an optional `-NNNN` ZIP+4 add-on.
  * **CA** -- `ANA NAN` (e.g. `K1A 0B1`). The bare 3-character forward
    sortation area (e.g. `T0A`) is also a complete, valid value on its own,
    not a truncated fragment -- real-world data (GeoNames' worldwide postal
    code table) is overwhelmingly this shape for Canada, not the full 6
    -character form. D, F, I, O, Q and U never appear in any letter
    position; W and Z additionally never appear as the first letter.
  * **FR** -- 5 digits; a prefix is not a postcode. `CEDEX` is accepted and
    normalised away: `FR-75054 CEDEX 01` is stored and rendered as `FR-75054`.
    A CEDEX code is a real, distinct postcode (in GeoNames' FR rows, ~28% carry
    a CEDEX suffix, and nearly all of those 5-digit parts appear nowhere else
    as a bare code), and `CEDEX [n]` is address routing, not part of the code.
    The grammar is exactly `NNNNN`, `NNNNN CEDEX` or `NNNNN CEDEX n` -- not
    "ignore whatever follows the digits", so `75001 foo` is still an error. The
    few other oddities in that data (`SP 07`, `AIR`, `CITYSSIMO`: 21 rows of
    51,611) are rejected.
  * **BR** -- 5-digit base + optional 3-digit suffix (`NNNNN-NNN`, the CEP).
    Unlike US's `+4`, the suffix has no free value to use as an "absent"
    sentinel (`000` is itself a common real suffix), so presence is a
    dedicated bit rather than inferred from the value.
  * **CZ** -- 5 digits, conventionally rendered `NNN NN`.
  * **LU** -- `L-` + 4 digits; the `L-` is part of the canonical form here
    (unlike US/CA's own separators, which are input-only conveniences),
    since real Luxembourg data is essentially always written this way.
  * **GB** -- the existing `postcode` type's 32-bit value, carried unchanged in
    the payload and parsed by the same code (`postcode_parse`), so the two types
    cannot drift apart. The outcode (`SW1A`, `LS24`) is a complete value. Also
    assigned to GG, IM and JE, whose areas (GY, IM, JE) are already in the UK
    layout.
  * **IE** -- Eircode: a routing key (`A65`, or the one exception `D6W`) that is
    a complete value on its own, optionally followed by the 4-character unique
    identifier (`A65 F4E2`). Every character comes from 25 symbols: the digits
    and the letters A C D E F H K N P R T V W X Y.

### Loading messy data

`::postal_code` and `postal_code(postcode, cc)` are strict: a bad value raises, which
aborts a whole `COPY`/`INSERT`. For feeds that contain rows which aren't valid
postcodes, `to_postal_code()` returns NULL instead (the role `topostcode()`
plays for the UK type), so the load can finish and the rejects can be found
afterwards. It comes in the same two forms as the strict constructors:

    SELECT to_postal_code('FR-75054 CEDEX 01');        -- like ::postal_code
    SELECT to_postal_code('75054 CEDEX 01', 'FR');     -- like postal_code(postcode, cc)

    INSERT INTO addresses (pc) SELECT to_postal_code(code, country) FROM staging;
    SELECT * FROM staging WHERE to_postal_code(code, country) IS NULL;

`is_valid()` answers the same question as a boolean, in the same two forms, for
`CHECK` constraints or for finding the rejects in a staging table (NULL in gives
NULL out, so a `CHECK` lets NULLs through):

    SELECT is_valid('CA-D1A 0B1');                   -- false: D is never used in a Canadian code
    ALTER TABLE staging ADD CHECK (is_valid(code, country));

It is exactly `to_postal_code(...) IS NOT NULL`, so every per-country rule
(Canadian excluded letters, Eircode's alphabet, ZIP+4 `0000`, ...) is enforced
by the same parser at ingest and in `is_valid()` -- they cannot disagree.

**What counts as the same code.** Real data spells one code several ways, so some
differences of spelling are not errors. Anything a format accepts as written is taken
as written. Only if that fails are these tried, in this order, and the first that
parses wins:

* the country's own letters dropped from the front -- `MH96960`, `AI 2640`,
  `US 90210`, `LU1471` (the country is already known). Jersey, Guernsey and Isle of
  Man codes start with their country's letters, but they are tried as written first,
  so `IM1 1AA` is unaffected and `IM1 SPT` is still rejected;
* spaces and hyphens swapped -- `1050 010` for `1050-010`, `L 1820` for `L-1820`;
* spaces dropped -- `06 830`, `19 801`, `K1A0B1` -- or dots, as in the Brazilian
  `06.026-170`.

Beyond that, a Brazilian CEP and a US ZIP+4 may be written without their hyphen
(`01139020`, `902101234`), which is how they usually are.

Before any of that the text is tidied: spacing at the ends, doubled spaces and
spaces next to a hyphen (`" us - 90210 "`), and, in a UTF-8 or SQL_ASCII database,
other scripts' spelling of the same characters: digits of other scripts become 0-9
(Persian `۱۱۴۱۶`, Arabic-Indic, Bengali `১২১৪`, Burmese `၀၇၀၉၁`, Devanagari `४००००१`,
Thai, full-width), the Unicode hyphens and minus signs become `-` (`050−0083`,
`064‐0915`), no-break and other Unicode spaces become a space, full-width letters
become ASCII, and zero-width characters and Japan's postal mark `〒` are dropped.
These only re-spell the same characters, so they can
recognise a code but never turn something that isn't one into one: a value that parsed
before parses to the same value now. Text *around* a code is a different job and is
not attempted -- `DE 19801`, `NSW 2000`, `ON L6M 0A8`, `1200-445 LISBON`, `CAP 00144`,
`PO BOX 3085` are all rejected. Pulling the postcode out of address text is data
cleaning, to be done before the value reaches this type.

### Locking a column to a country

Like PostGIS locking a geometry column to an SRID with `geometry(Point, 4326)`, a
column can be locked to a country with a type modifier:

    CREATE TABLE addresses (id serial, pc postal_code('US'));
    INSERT INTO addresses (pc) VALUES ('US-10001');     -- a prefix that agrees with the column
    COPY addresses (pc) FROM stdin;                     -- COPY may use bare national codes: 90210-1234
    INSERT INTO addresses (pc) VALUES ('CA-K1A 0B1');   -- ERROR: country "CA" does not match the column's country "US"
    SELECT * FROM postal_code_columns;                   -- which columns are locked to what

It is enforced wherever a value enters a column -- `INSERT`, `UPDATE`, `COPY` (text
and binary), `::postal_code('US')` and `ALTER COLUMN ... TYPE postal_code('US')`
(which fails if any existing value is from another country). An unlocked column
still requires the `CC-` prefix.

Bare national codes (no `CC-`) are accepted **only by `COPY`**: PostgreSQL passes a
string literal to the input function without the column's type modifier and applies
the modifier afterwards, so in `INSERT`/`UPDATE` the prefix is always needed. To load
bare codes with SQL use `postal_code('90210', 'US')`.

* It locks the **country**, not the format, so a country that moves to a new format
  keeps working in its column.
* As with any type modifier it is enforced on assignment and casts; a value merely
  returned from a function is not re-checked.
* The modifier's *shape* (two letters) is validated when the column is declared,
  but not whether the country is currently assigned a format. That is deliberate:
  the column definition has to survive a dump and restore before the data in
  `postal_code_country_formats` does. A lock to a country with nothing assigned is
  harmless -- every insert into it fails.
* There is no storage saving: the value is a fixed 8 bytes and the country stays in
  every row. The gain is integrity, and the bare-text convenience.

### Outcode

`outcode(pc)` (and `district(pc)`, the same function) is the area part of a
postcode **as a complete valid postcode of its own**:

    SELECT outcode('GB-SW1A 1AA');       -- GB-SW1A
    SELECT outcode('US-90210-1234');     -- US-90210
    SELECT outcode('CA-K1A 0B1');        -- CA-K1A
    SELECT outcode('IE-A65 F4E2');       -- IE-A65
    SELECT outcode('BR-01310-100');      -- BR-01310
    SELECT outcode(pc), count(*) FROM addresses GROUP BY 1;

It is idempotent (an outcode is its own outcode), and the outcode sorts before
every full code inside it. For FR, CZ and LU, where the leading digits are only
*implicitly* an outcode, there is nothing to extract and the result is NULL
rather than a whole code passed off as an area (the full code is required there,
as for validity). It is also NULL for the end-of-country bound, which is not a
postcode. `outcode()` is `IMMUTABLE` -- it reads only the value's own bits, never
the country table -- so it can be indexed: `CREATE INDEX ON t (outcode(pc))`.

### Partial match and ranges

A *fragment* is `CC-` plus a **prefix** of the national code -- `GB-LS24`, `FR-75`,
`CA-K1A 0` -- and matches every value that starts with it. Each format orders its
values exactly as its text sorts, so a prefix is one contiguous range, and
neighbouring prefixes tile with no gap and no overlap. A fragment is not a value:
`FR-75` is a fragment but not a postcode.

    SELECT * FROM addresses WHERE pc <@ postal_prefix('GB-LS24');   -- the range type
    SELECT lower_bound('CA-K1C'), upper_bound('CA-K1C');             -- CA-K1C, CA-K1E

* `postal_prefix(fragment)` returns a `postal_code_range`, a native PostgreSQL
  range type, so `<@`, `@>`, `&&`, `-|-` (adjacent) and multiranges all work.
* `lower_bound()` is the smallest *valid* value in the range (inclusive), e.g.
  `lower_bound('CA-K')` is the outcode `CA-K0A`. `upper_bound()` is the smallest
  valid value *past* it (exclusive), skipping symbols a format never uses
  (Canada's `D F I O Q U`, Eircode's missing letters) and carrying into the next
  sibling at the level above: a real postcode wherever a successor exists.
* **The top of a country has no successor value**, e.g. `US-99`, `FR-9`, the last UK
  area. There the upper bound is that country's **end-of-country bound**,
  written `US-~`: a value that sorts after every real value of the country and
  before the first of the next (`~` is the highest printable character, so it sorts
  last as text too). So `postal_prefix('US-99')` is `[US-99000,US-~)`, and
  `pc < upper_bound(...)` is right at the top of a country as well. A range is never
  left open-ended, because PostgreSQL's "no upper end" means the end of the *whole*
  value space and countries lie end to end in it: `[BR-99000,)` would run on through
  CA, CZ, ... US. (Found by comparing every prefix in 148k real rows against a plain
  text `GROUP BY`; a design that used an open end looked right only while the country
  in question was the last one assigned.)
* Bounds are bounds, not addresses. A bound that is the successor of a prefix need
  not be a code anyone has, and using one as a postcode is bad practice. `US-~` is
  accepted as input so a stored range survives a dump and restore, but nothing treats
  it as a postcode: `is_valid('US-~')` is false and `to_postal_code('US-~')` is NULL.
  (`'US-'` with nothing after the hyphen is still an error, so an empty code in a
  concatenation cannot quietly become one.)
* The UK rule is kept: `GB-LS1` is district LS1 only, not LS1x (all available
  digits go to the district unless a space says otherwise). GB's area list is
  append-only, so "the next area" is the next in *encoding* order (`ZE` is followed
  by `GX`) -- the order the values themselves compare in, so tiling still holds.

**Index use.** `pc <@ postal_prefix('GB-LS24')` uses a btree index on `pc`. A call
with a constant fragment is folded into a constant range at plan time, and
PostgreSQL's own rewrite of `col <@ <constant range>` into plain btree conditions
then applies (`pc >= lo AND pc < hi`).
That rewrite is PostgreSQL 15 and later; on 14 the query is still correct but is a
filter. `postal_prefix()` is `STABLE` rather than `IMMUTABLE` because the answer
depends on which format a country is assigned, so the folded plan is made to depend
on `postal_code_country_formats` and a trigger invalidates cached plans whenever
that table changes -- a reassigned country cannot leave a stale plan behind (this
is tested with a prepared statement).

### The `%` operator

`pc % 'GB-LS24'` is true when `pc` starts with the fragment, and `pc !% 'GB-LS24'`
when it doesn't -- the UK type's operator, ported. It means the same as
`pc <@ postal_prefix('GB-LS24')`, with the UK operator's leniency: a fragment that
isn't one (no `CC-`, an unassigned country, not a prefix of that format) matches
nothing, and `!%` matches everything, because `%` is meant for arbitrary input such
as a search box where an error would be the wrong answer. `postal_prefix()`,
`lower_bound()` and `upper_bound()` still raise on a bad fragment.

With a constant fragment the planner rewrites `pc % 'fragment'` into
`pc >= lo AND pc < hi`, so it uses a btree index through the ordinary sound
strategies. `%` is deliberately *not* registered in the btree operator family (it
is not an equivalence relation: two different codes can both match one fragment).
Like `postal_prefix()`, the rewritten plan depends on `postal_code_country_formats`
and is invalidated when it changes.

### Adding a country

Which format a country uses is a live SQL table
(`postal_code_country_formats`), not compiled in. Assigning a country to a
format that already exists needs no rebuild:

    SELECT add_country_format('DE', 'FR');   -- Germany: same plain 5-digit shape as FR/CZ
    SELECT 'DE-12345'::postal_code;          -- works immediately, no extension reinstall
    SELECT remove_country_format('DE');      -- undo -- new DE text stops parsing, but
                                              -- values already stored as DE are unaffected
                                              -- (decoding uses the format bits already in
                                              -- the value, never a fresh lookup)

`SELECT * FROM postal_code_formats` lists the formats a country can be assigned;
`add_country_format()` raises if you name one that isn't there. A country whose
codes are just fixed-width groups of digits and letters needs no C at all -- see
the next section. Only a genuinely irregular format (Canada's excluded letters,
Ireland's Eircode, the UK's area table) needs real C (in `postal_code_fmt.c` and a
new `postal_code_fmt.h` tag) and a new extension version.

### Every country in the world

The extension ships with a format for every country and territory that has a postal
code system: 194 of the 250 ISO 3166-1 entries (the other 56 have no postal codes,
and the table says so). Eight formats are compiled (US, CA, FR, BR, CZ, LU, GB, IE);
the rest are templates (below). The formats come from the real GeoNames data
(`"@GEONAMES".world`, 120 countries and 1.65 million codes, every one of which loads
except 21 French non-codes) and, for countries it doesn't cover, Wikipedia's list of
postal codes. Territories that use another country's system share its format
(`PR`, `GU`, `VI`... use the US one, `RE`, `GP`, `MQ`... the French).

    SELECT * FROM postal_code_world;                      -- every country, its format, where it came from
    SELECT * FROM postal_code_world WHERE basis = 'no postal codes';
    SELECT * FROM postal_code_world WHERE note IS NOT NULL;   -- the judgement calls

The UAE has no postal codes, but two schemes work like them: Abu Dhabi's 5-digit
district codes (`20000`, `23251`) and Dubai's Makani numbers, a 10-digit code for each
building written `NNNNN NNNNN` (all that GeoNames holds for the UAE). One format,
`NNNNN[ NNNNN]`, holds both, so any five digits pass, and the `postal_code_world` note
says what it is. Sharjah's PCS is not modelled, because there is nothing here yet to
say what its codes look like; PO Box numbers, which is what most UAE addresses give, are
not codes and are rejected.

Two things to know. A template can't fix digits, so French Guiana's `973NN` is just
the French five digits; where the real rule is narrower than the format, the format
accepts a little too much. And where the sources disagree or are doubtful (Egypt,
Myanmar, Vietnam, Israel) the format accepts both lengths. Both are recorded in
`note`. The table is generated by `tools/world_formats.py`; changing a built-in
country is a new template for it (old values keep reading as written), done through
`add_country_template()` like any other.

### Templates: new countries without C

    SELECT add_country_template('XA', 'NN-NNN');          -- a (made up) country
    SELECT add_country_template('XB', 'NNNN[ AA]');       -- 4 digits, optionally + 2 letters
    SELECT add_country_template('XC', 'NNN[-NNNN]');      -- 3 digits, optionally + 4
    SELECT add_country_template('XD', 'CCNNNN');          -- the country's own letters, then 4 digits
    SELECT add_country_template('XE', '[A]NNNN[AAA]');    -- an optional province letter in front (Argentina)
    SELECT 'xa-00950'::postal_code;                       -- XA-00-950

A template is written with `N` (a digit), `A` (a letter), `X` (either), the
separators space and hyphen, at most one optional `[ ... ]` group at the end, and
optionally `CC` first or a leading `[A]` group. Separators are always written and optional on input, and
letters are accepted in either case. Everything else works as for the built-in
formats, with nothing more to configure: ordering is text ordering
(`'PL-00-949' < 'PL-00-950'`, countries in ISO order), prefix ranges,
`lower_bound`/`upper_bound`/`postal_prefix`, the `%` operator and index use,
`outcode()`, `is_valid()`/`to_postal_code()`, the country lock, and binary
send/receive.

* **`CC` is the country's own letters.** Some countries write the ISO code into the
  code itself: `VG1110` in the British Virgin Islands, `AD500`, `AZ 1000`, `HT6110`.
  A template starting `CC` (`CCNNNN`, `CC NNNN`) says so: on input those letters are
  optional, must be the country's own (`XX1110` is not a Virgin Islands code), and
  are neither stored nor written back. `VG1110`, `VG-1110` and `VG-VG1110` are one
  value, written in the UPU form `VG-1110` -- as Latvia's `LV-1050` is. (A hyphen
  after the country, as in `LV-1050`, needs no template support: the type already
  strips it.)
* **A leading optional group of letters.** Argentina writes `1832`, `B1832` (province
  letter) and `B1832GMR` (the full CPA); `[A]NNNN[AAA]` holds all three. The leading
  group must be letters and the code after it must start with a digit (`N`), so codes
  without the group sort first -- digits sort before letters -- and text order still
  holds. It cannot be combined with `CC`.
* **The optional group is the incode.** The part before it is a value of its own and
  is the `outcode()`; it sorts just before every value that extends it (`NL-1012`
  before `NL-1012 AA`). A template with no optional group has no outcode, like
  France.
* **No special rules.** A template cannot say "this letter is never used" or "0000
  is not a real suffix": every combination its shape allows is valid. Where a
  country needs that (the US rejects `-0000`; Canada excludes D, F, I, O, Q and U),
  it takes a compiled encoder, or else a template that accepts a little too much.
* **It must fit in 48 bits**, which allows e.g. 14 digits or 9 alphanumerics, and
  `add_country_template()` says so if it doesn't.
* **A template is permanent.** Each template occupies one of 51 slots
  (`postal_code_templates`), and a stored value carries its slot as its format, so
  it is always read the way it was written -- exactly as the built-in formats are.
  Rows cannot be updated or deleted. To change a country's format, assign it a
  *new* template: new values follow it, and values already stored go on reading as
  they were written (and are different values -- `PL-00-950` under `NN-NNN` is not
  equal to `PL-00950` under `NNNNN`). Countries with the same shape share a slot.
* **Dump and restore.** Everything you add survives a dump and restore: the
  templates (`postal_code_templates`) and your country assignments
  (`postal_code_user_countries`) are dumped with the database. What ships with the
  extension (`postal_code_builtin_countries`) is recreated by `CREATE EXTENSION`
  and is not. `postal_code_country_formats` is the view that merges the two (a
  user row wins; its `builtin` column says which each row is). Change assignments
  only through `add_country_format()`, `add_country_template()` and
  `remove_country_format()` -- removing a built-in assignment records that fact
  rather than deleting the shipped row.

  **One restore caveat.** The type's text input needs the country assignments, and
  `pg_restore` orders table data by name, so a table that sorts before
  `postal_code_user_countries` (say `addr`) can be loaded first and fail with
  `"PL" is not a supported country code`. Restore the extension's own data first,
  by reordering the restore list (tested):

      pg_restore -l db.dump > all.list
      grep -E 'TABLE DATA public postal_code_(formats|templates|user_countries) ' all.list > cfg.list
      awk -v cfg=cfg.list 'BEGIN{while((getline l < cfg)>0) c=c l "\n"}
          /TABLE DATA public postal_code_(formats|templates|user_countries) /{next}
          {print} / EXTENSION - postcode( |$)/{printf "%s", c}' all.list > ordered.list
      createdb -T template0 newdb
      pg_restore -L ordered.list -d newdb db.dump

  (Values already *stored* never need any of this; it is only the text form read
  back from a plain dump.)

One consequence worth knowing: `postal_code_in`/`postal_code(text, text)`
are declared `STABLE`, not `IMMUTABLE`, precisely because their result can
change if a country's assignment changes -- so, correctly, PostgreSQL will
refuse to let you build a functional index over a `::postal_code` cast or
the two-argument constructor (`CREATE INDEX ... (('US-' || col)::postal_code)`
errors: "functions in index expression must be marked IMMUTABLE"). Indexing
the already-typed column itself (`CREATE INDEX ON t (pc)`) is unaffected --
that only compares stored values, never re-parses text.

See `postal_code.h`/`postal_code_fmt.h` for the bit layout and dispatch
design, `postal_code_country.c` for the country->format lookup, and
`sql/postal_code.sql`/`expected/postal_code.out` for the regression tests
(including a small, checked-in slice of real GEONAMES.world data).

Binary send/recv, a btree opclass, and full comparison operators are
provided the same as for `postcode`. Partial matching is the range support
and the `%` operator described above.


Credits
-------
Developed up to 1.3.0 by Dave Green at patchsoft.
Taken up for bug fixing and gap filing by John Burn of Impact Data Metrics. The bulk of the code is from David Green.
Claude AI was used to analyse and apply code fixes and generate tests

Bugs
----
Regression tests are provided using pg_regress via the installcheck target. Please raise issues on the githib site or PGXN


