# Schemes defined by a list of codes

Status: **the engine part is built and tested; the SQL layer is a proposal.** Branch `feat/list-schemes` (on top of
`fix/dfa-use-after-free`, pull request 5).

## Why

A scheme whose valid codes are a published list (SIC, SOC, NUTS, ICD-10) can be written as a regular expression only up to a
point. The text of the pattern, and the automaton the engine compiles from it, are both as big as the *tree* of the codes,
though the smallest automaton for them is much smaller, because endings are shared. Limits that bite: the helper buffers
(4,096 characters; trivial to remove), the compiler's 2,048 states (about 1,300 to 4,000 codes), 60,000 NFA states, and about
1 KB of tables per state per backend. A regex optimiser cannot fix that: a regex cannot share structure between branches.

## What is built

`pc_pattern_from_list(codes, n, alloc, err, errlen)` in `postal_code_pattern.c`: a sorted, duplicate-free list of codes in,
the **smallest** automaton out, in the same tables `pc_pattern_compile` produces. So parse, render, prefix ranges, outcode and
`pc_pattern_same_codes` work on it unchanged, whichever way a pattern was made.

Method: the codes are sorted, so those sharing their first `depth` characters are consecutive. Split such a run by the next
character, build each part, and give the state its (accepting?, edges). A state with the same accepting flag and edges as an
earlier one *is* that state. One pass, post-order, no pattern text, no NFA. Checks first (sorted, no duplicates, upper case,
printable, at most 40 characters), each with the position of the offending code in the message.

## Evidence (`test_postal_code_listbuild.c`, 900 checks, also clean under AddressSanitizer and UBSan)

* **Same as the regex path.** For 216 random lists (digits, clustered, and mixed lengths where many codes are prefixes of
  others): the same codes in the same ranks (render and parse), the same range for every prefix of every code, the same outcode,
  `same_codes` says equal, and never more states than the regex compiler produced.
* **Smallest possible.** Its number of states equals the number of distinct sets of endings, counted by an independent method
  (not an automaton) that was itself checked by hand.
* **Long lists.** 4,785 / 30,779 / 70,283 ICD-10-like codes: 2,739 / 5,902 / 6,767 states, 2.5 / 5.4 / 6.2 MB, built in 1 / 2 / 3 ms;
  every rank, every parse, 3,549 / 23,629 / 55,906 prefix ranges, and 2,000 non-codes agree with the list itself.
* **Against the regex route** (same kind of list, limits raised to let it compile at all): 12,970 codes needed 5,863 states by
  regex and 2,287 as a list (2.6x fewer); 38,951 codes 15,397 and 5,015 (3.1x fewer). Against the raw tree of the codes the
  saving is 6.7x to 8.7x, which is a different comparison.
* **Refused with a reason:** unsorted, duplicate, empty, lower case, non-ASCII, over 40 characters, no codes at all, and a list
  whose automaton needs more than 32,767 states (the transitions are 16-bit): 150,000 random 8-digit codes.

## Limits that remain

* **16-bit transitions: 32,767 states.** Lists with shared endings (SIC, ICD-like) use a fraction of that; random codes with no
  structure do not (150,000 random 8-digit codes need far more). Moving to 32-bit transitions would double `next`.
* **Memory: about 970 bytes per state**, dominated by the dense table of "codes behind each smaller character" (96 x 8 bytes
  per state), kept per backend per scheme. Fine for thousands of states; a sparse table (most states have a few edges) would
  cut it about five-fold and is the obvious next optimisation. Not needed for SIC (154 states).
* **Codes only.** A list has no regular expression, so no named parts from the pattern. Parts for a list would be a parts-only
  pattern or fixed widths (SIC: 2, 1, 1, 1), the way the compiled formats do it.

## Proposal for the SQL layer (not built)

```sql
SELECT add_country_list('XS', ARRAY['01110','01120', ...]);               -- or
SELECT add_country_list('XS', 'SELECT sic FROM "@SIC"._sic2007_ons ...');    -- from a query
```

* A table of the codes, `postal_code_list_codes(iso2, version, code)`, permanent like `postal_code_languages` (its rows are what
  stored values are decoded with), dumped with the database. `postal_code_languages` gains a `kind` ('pattern' or 'list');
  for a list `pattern` is unused.
* `pc_language_for` loads the codes in byte order, builds the automaton once per backend, and caches it as now.
* The rules carry over: the same codes never make a new version (the exact comparison works on any two automata); a different
  list is the next version; a built-in is never edited. Editions of a classification (SIC 2003, 2007) are separate schemes.
* `add_country_list` checks the list as `pc_pattern_from_list` does and says where it is wrong; a list from a query is sorted for
  you.
* **Open:** the shape of parts for a list; whether to reserve the user-assigned codes (AA, QM-QZ, XA-XZ, ZZ: 42 in all) or move
  to the one-type-per-scheme design discussed earlier, where this engine is the shared part; the restore-ordering caveat (the
  codes table must be loaded before the data, as for languages).
