# Validation on real data

`postal_code` was run against about 117 million postcodes from OpenStreetMap, 1.8 million from
GeoNames and 24,000 foreign registered offices from Companies House before release. This records what
was done, what it found, and what is still imperfect. Everything here can be re-run
(see "Reproducing").

## What was tested, and on what

| Data | Size | Source |
|---|---|---|
| OpenStreetMap `addr:postcode` and `postal_code` tags | 117,537,690 values, 2,149,363 distinct (country, tag, value), 209 countries | Geofabrik's per-country extracts, 188 files |
| GeoNames postal codes | 1,826,904 codes, 121 countries (including the UAE's 178,171) | `"@GEONAMES".world` |
| Companies House non-UK registered offices | 24,244 postcodes, 197 country spellings | `"@COMPANIESHOUSE".ch` |
| UK postcodes, for the `1.3.5 -> 2.0.0` upgrade | 829,216 distinct codes | the OpenStreetMap GB extract |

The country of an OpenStreetMap value is the file it came from, or its `addr:country` tag where present.
Extracts overlap borders, so a few countries show a neighbour's codes (Northern Ireland's `BT` codes in
the Ireland file, French codes in Luxembourg's, Dutch codes in Germany's); those are noise, not defects.

## Results (final build)

| Check | Result |
|---|---|
| OpenStreetMap `addr:postcode` values parsed | **99.84%** of 116.3 million (97.49% of distinct values) |
| OpenStreetMap postcode areas (`postal_code=*`, the mapped areas) | **99.42%** of 1.18 million |
| GeoNames | 1,826,904 codes in 121 countries: all load except 21 French non-codes and one American Samoa ZIP filed under Samoa |
| Companies House non-UK registered offices | **94.2%** of 24,244 parse; the rest are PO boxes, placeholders and text around a code |
| Round trip through text, 1,978,596 distinct parsed codes | 0 failures |
| Round trip through `COPY ... (FORMAT binary)` | 0 lost, 0 invented |
| Country of the value equals the country it was parsed for | 0 mismatches |
| `outcode()` idempotent, and never after its value | 0 failures |
| `is_valid()` agrees with `to_postal_code()` | 0 disagreements |
| Type order equals text order, within each country | 0 out of order (one documented exception, below) |
| Prefix ranges: 694,144 distinct prefixes of those codes, `postal_prefix` count against a plain text count | **0 mismatches**, 0 fragments refused |
| `1.3.5 -> 2.0.0` upgrade of a database holding 829,216 UK postcodes | identical checksums before and after, same partial-match results, and the same 143 extension objects as a fresh 2.0.0 install |
| `pg_dump` and `pg_restore` of that database (829,216 codes in each of the two types) | both tables reproduced exactly, by plain restore and by the reordered restore list |
| Countries recorded as having no postal codes | checked against OpenStreetMap: their values are placeholders (`00000`), dialling codes (`+218`) and `BP` box numbers, with no consistent format |

## What the testing found, all fixed

* **`pg_dump` failed on any database with the extension installed.** A configuration-table condition
  named a table unqualified, and `pg_dump` runs with an empty `search_path`. Found by dumping a real
  database. A regression test now runs every dump condition under an empty `search_path`.
* **The same empty `search_path` broke the country and template lookups during a restore.** They now
  name their tables with the extension's schema.
* **Other scripts' digits, dashes and spaces** (Persian, Arabic-Indic, Bengali, Burmese, Devanagari,
  Thai, full-width digits; Unicode hyphens and minus signs; no-break spaces; zero-width characters;
  Japan's `〒`; Malta's native letters) are re-spelled as the ASCII they stand for.
* **Brazil's CEP** is usually written without its hyphen (39,445 values) or as `06.026-170`; a US
  ZIP+4 likewise may lack its hyphen.
* **Argentina's province letter** (`B1832`, `B1832GMR`) is 21% of its 831,000 values; templates gained
  an optional leading group of letters to hold it.
* **Fragments** may stop part-way through a UK unit (`M14 6Q`), or right after a ZIP+4 or CEP hyphen
  (a text prefix, so it excludes the bare code), and `L-` is every Luxembourg code.
* **Colombia, Mozambique and Iran** take their optional extension block; Panama takes 4 and 5 digits.
* **The UK format now enforces Royal Mail's letter rules** (unit letters never C I K M O V; the letter
  after the digit of an A9A or AA9A outcode from a fixed set), which the `postcode` type has never done.
  In 7.7 million real UK codes only 24 broke them -- typos such as `NG12 4FO`, letter O for zero -- and
  none broke the outcode rules, so they cost almost nothing and catch real mistakes. Canada's format
  already enforced its equivalents.
* **Spacing and country-letter variants** (`MH96960`, `1050 010`, `06 830`, `L - 2226`) are recognised,
  without changing anything that already parsed.

## Known gaps, not fixed

These are real forms the formats do not hold, listed with how much of the data they are.

* **Taiwan `NNN-NN`** (the older 5-digit form, 0.4% of Taiwan's values) and **Ghana's 6-character
  form**: a template holds one optional tail, so it cannot accept three lengths.
* **Kazakhstan's newer alphanumeric codes** (`A05B1H4`, 606 values, under 2%) and **Myanmar's
  `NNNN-NNNN`** (778 values): too little evidence of the real rule to model.
* **Leading zeros lost in the source** (France `1000` for `01000`, Italy, Germany, Finland, Croatia):
  rejected, deliberately, rather than guessed.
* **Text around a code** (`DE 19801`, `NSW 2000`, `1200-445 LISBON`, `PO BOX 3085`), lists and ranges
  (`08296, 08297`, `07500-07571`): data cleaning, not a postcode.
* **Single-code territories** (the British Overseas Territories, Vatican, San Marino, Monaco, the
  French territories) accept any code of the right shape, since a template cannot fix digits.
* **The UK format's `GX` (Gibraltar) sorts after `ZE`**, not alphabetically, because the area list is
  append-only; and a bare area letter (`GB-A`) is not a fragment because the areas starting with it are
  not contiguous. The UK format also reads `GB-AB1` as district 1 and `GB-B` as area B, so it is
  checked structurally (outcodes, sectors, units) rather than by plain text prefix.
* **Jordan's `JOR…` national address codes, Kenya's `107 Kiambui`, `00000` placeholders, dialling
  codes, plus-codes** appear in the `postcode` tags and are rejected, correctly.

## Reproducing

```
tools/osm_run.py          download each Geofabrik country extract and count its postcodes
tools/osm_extract.py      the per-extract counter (pyosmium)
tools/osm_validate.sql    the checks above, over a table osm_raw built from the counts
tools/world_formats.py    the country -> format table, with where each format came from
```

`osm_run.py` expects `selected.json` (the country files, from Geofabrik's `index-v1-nogeom.json`) and
writes one CSV per country; load them into `osm_raw(files, src, ac, value, n)` and run
`psql -f tools/osm_validate.sql`. Tens of gigabytes are downloaded and discarded (the US file alone is
12 GB); the CSVs are 46 MB. In the 12-core test container the download and extraction took about an hour
and the validation script about fifteen minutes.
