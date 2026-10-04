# Tightening formats with patterns: a review

A *template* says how a code is built (`NNNN`, `NNN NN`); it cannot say which codes are **allowed** within
that shape. A *pattern* -- a bounded regular expression -- can, and in 2.0.0 a country's pattern is its
whole definition (see `README.md`): a code is stored as its rank among the codes the pattern allows, so
order, validity and prefix ranges are exact and a range's bounds are always real codes. This records which
countries and territories have restrictions, tested against the data, and which were adopted.

**Compiled, not by pattern:** Canada (the excluded letters D F I O Q U, and first letters W and Z), Ireland's
Eircode alphabet, and the UK (Royal Mail's letter rules: unit letters never C I K M O V, and the letter sets
of A9A and AA9A outcodes) are enforced by their compiled encoders. **By pattern:** every rule below, and
everything else that is not US, CA, FR, BR, CZ, LU, GB or IE.

## How the rules were checked

A rule is only trusted if it rejects **no** GeoNames code (1.8 million, a cleaner source than OpenStreetMap).
What it rejects among OpenStreetMap's 2 million parsed codes shows what it would catch. Of 59 candidate
rules, 53 reject nothing in GeoNames. The six that did were corrected, or dropped:

* French overseas: GeoNames files `977xx` (Saint-Barthélemy and Saint-Martin) and `970xx` under Réunion and
  Guadeloupe, and writes `97305 CEDEX` for Cayenne -- the departments use CEDEX like France. A `97xxx`/`98xxx`
  pattern rejected 303 GeoNames codes in the final check, so the territories keep the French format and
  no rule is applied (the single-code rows `PM`, `BL`, `MF` in the table below are likewise not narrowed).
* Turkey: `01`-`81`, **and `99`** (the Turkish-controlled north of Cyprus, 57 codes).
* Singapore: `01`-`82` is wrong; `88`, `91` and others are used (Changi). Not tightened.

## What can be tightened (rules that reject nothing in GeoNames)

| Kind | Countries | Pattern (canonical form) |
|---|---|---|
| First digit is never 0 | AT BE BG CH CY HU SI EE SE IS FO BD CL CU IN NI PK UY TN PT | `[1-9]\d{3}`, `[1-9]\d{4}`, `[1-9]\d{2} \d{2}` ... |
| Greece | GR | first digit 1-8: `[1-8]\d{2} \d{2}` |
| First two digits are a province or area | DE UA MX MY `01`-`99`; ES `01`-`52`; KR `01`-`63`; TR `01`-`81` or `99` | `(0[1-9]\|[1-4]\d\|5[0-2])\d{3}` |
| A fixed prefix | MC `980xx`; SM `4789x`; VA `00120`; LI `9485`-`9498`; AX `22xxx`; AD `1`-`7`xx | `980\d{2}` ... |
| A single code | FK `FIQQ 1ZZ`, GS `SIQQ 1ZZ`, IO `BBND 1ZZ`, PN `PCRN 1ZZ`, TC `TKCA 1ZZ`, AQ `BIQQ 1ZZ`, SH `STHL`/`ASCN`/`TDCU 1ZZ`, AI `2640` | the literal |
| Letter sets | NL: digit 1-9, letters never F I O Q U Y, never `SA` `SD` `SS`; AR: province letter never I or O; SZ: `H` `L` `M` `S` | `[1-9]\d{3} [A-EGHJ-NPRSTVWXZ]{2}` |

Not expressible as a pattern: lists of valid codes (the UK's roughly 3,000 outcodes, the US's valid 3-digit ZIP
prefixes, a country's actual towns). Those would be data, not a pattern.

## What it would be worth

On OpenStreetMap's 2 million parsed codes the confirmed rules would reject about **120** distinct values,
0.006%. Nearly all are placeholders (`0000`, `00000`) or a neighbouring country's codes in a border extract
(French `64220` in Spain's file, Swiss `6800` in Liechtenstein's, Italian `00185` in the Vatican's). The value is
rigour at the edges, not volume: it makes "valid" mean more, and it makes the single-code and fixed-prefix
territories exact instead of "any code of this shape".

## What was decided

The ranked-pattern engine (`postal_code_pattern.c`) was built, as the table and the numbers above suggested.
A narrowing pattern per country would have left a range's bounds able to be codes the pattern rejects; ranking
the codes of the pattern itself makes the bounds exact and wastes no bits, and it also holds the cases a
template cannot (Taiwan's 3, 5 or 6 digits, Ghana's 5 to 7 characters, Kazakhstan's two forms). Each country
has its own numbered versions of its pattern (51), so exact per-country patterns do not compete for a global
set of slots.

One thing a pattern cannot settle: with the separator dropped, `SW11` is read as the outcode `SW11`, not as
`SW1 1`, because for outcode and sector text the separator carries meaning. A full postcode is unambiguous,
since its last three characters are the incode.
