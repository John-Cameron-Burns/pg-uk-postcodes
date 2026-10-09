# Named parts: `(?<name>...)` in patterns

Status: built for 2.1.0 -- the engine (`postal_code_pattern.c`), the SQL layer (`postcode--2.0.1--2.1.0.sql`,
`postal_code.c`, `postal_code_lang.c`), and tests at three levels: the standalone engine
(`test_postal_code_parts.c`), the compiled formats against their encoders (`test_parts_gb.c`,
`test_parts_compiled.c`), and the regression test `sql/parts.sql`. Branch `dev/postal_code-2.1-named-parts`.

## What it is

A pattern may name a part of a code:

    (?<area>[A-Z]{1,2})(?<district>\d[A-Z\d]?)( (?<sector>\d)(?<unit>[A-Z]{2}))?

A name changes nothing about which codes are valid, how they rank or how they are stored: the compiled
automaton passes straight through it. It only says where in a code the part is. Zero storage cost.

## Decisions, and the evidence

| Question | Decision | Evidence |
|---|---|---|
| Syntax | `(?<name>...)`. Names `[a-z][a-z0-9_]*`, at most 32 chars, at most 16 per pattern, unique. | Postgres' own regex has no named groups, but this engine parses its own subset. `(?<=`/`(?<!` (lookbehind) is refused with its own message. |
| Absent part | NULL. An optional part that is not in this code, or the other branch of an alternation. | UK-like: `sector`/`unit` absent in 1,800 of 73,800 codes; alternation: exactly one branch present. |
| A part that can match nothing | Refused at definition. | `(?<a>\d?)` and `(?<a>(\d)?)` fail with "can match nothing". Removes the NULL-vs-empty-string question. |
| Repeated part | Refused (`{2}`, `{1,3}`). Only `?` allowed. | A repeat would match more than once. |
| Nesting | Allowed; a parent's text includes its children. | `(?<code>(?<major>\d{2})(?<minor>\d{2})?)`. For a hierarchy, prefer sequential parts and a prefix function (below). |
| Which split when a code can be split two ways | First alternative that lets the whole code match; as much as possible for `?`/`{n,m}`. This is the NFA's own priority, so no extra rules. | In every test, including the deliberately ambiguous patterns, the engine agrees with the C library's POSIX matcher on every code (0 differences in about 247,000 codes). |
| Ambiguity | **Detect at definition and refuse**, in three tiers: every code if there are at most 10M of them; otherwise an exact static analysis of the pattern (up to 2,000 positions); otherwise a sample of 200,000 codes, reported as partial. | Static analysis matched brute force on 3,283 random patterns (950 ambiguous), 0 disagreements. It decides the 1.76-billion-code UK-like pattern in under a millisecond and finds an example in a 111-million-code ambiguous one. |
| Cost | Splitting a code adds about 145 ns on top of about 354 ns to render it. | 6.7M codes. Negligible beside the 55-64 us per-value input cost seen in the scratch-database test. |
| Existing 28M-check suite | Unchanged and passing. | `test_postal_code_pattern`: 28,054,543 checks, 0 failures. |

## Open design points

1. **Ambiguity check: decided** (see the table). Memory for the static analysis is about 9 bytes per pair of
   positions (up to about 72 MB at the 2,000-position limit), only while a pattern is being defined.
2. **Names are labels, the set is permanent: done.** A language row's pattern may be rewritten in place to any pattern
   that denotes exactly the same codes, judged by an exact comparison of the compiled automata
   (`pc_pattern_same_codes()`, `postal_code_same_codes()`; checked against brute force on 19,457 random pairs, 0
   wrong). It is not judged by text with the names stripped, which I tried first: `\d{2}-\d{3}` is not textually
   `(?:\d{2})-(?:\d{3})`, so "removing the names" made a new version. A built-in row is never edited (it comes back
   with the extension), so another spelling of a built-in language is the country's next language, as in 2.0.x.
3. **(done) The legacy `postcode` type** has `part()`, `parts()` and `prefix_of()` as overloads, read from its fields
   (`IMMUTABLE`, indexable); `prefix_of` returns the text `%` takes. Cost: with two types, a bare string literal is
   ambiguous and must be cast (columns are fine; `to_char` was always the same). Every `to_char` letter combination is
   tested against its replacement.
   **(done) The built-in patterns:** 29 of the 171 pattern countries are named (`tools/world_formats.py` `PARTS`,
   spliced into the upgrade script as UPDATEs that the permanence trigger only allows if the codes are unchanged).
   The other 142 -- one undivided number (about 106 of them), display grouping, two-length codes, single fixed codes -- have none. Names only where a system really has two kinds of
   information in a code, never for display grouping (SE, SK, GR) or a code of two lengths (IL, EG, VN).
   **Compiled formats** (US, CA, FR, BR, CZ, LU, GB, IE) store codes in their own layout, but their text is
   canonical. Ship a parts-only pattern for each, used only for splitting. Only the meaningful parts are named
   (US: ZIP and +4; BR: the CEP's region digits and suffix, not an arbitrary split). A CI test compiles each parts
   pattern as a ranked pattern and checks it denotes exactly the compiled format's set of codes, so the two
   definitions cannot drift apart.
   **GB: undecided.** See "The GB naming problem" below.
4. **Templates are only a wrapper for the regex** (the regex is what is compiled and stored). A name notation
   in the template form therefore just translates to `(?<name>...)`. Proposed: `(name:NNN)`, e.g.
   `(area:AA)(district:N[X])[ (sector:N)(unit:AA)]`; templates have no parentheses of their own.

## SQL layer (built)

    part(code, 'district')          text; NULL if absent; an error, listing the parts, if the country has no such part
    parts(code)                     jsonb of every part (null for absent); jsonb orders its own keys
    postal_code_parts               view: country, format, ord, name -- the parts each country has, in order
    prefix_of(code, 'group')        everything up to and including that part, as a postal_code_range
                                    (indexable, groupable, usable with <@)

- `part()`, `parts()` and `prefix_of()` are `STABLE` (they read the language table), so no functional index on them. Use
  `prefix_of()` and range bounds for index-assisted queries, as `%` does.
- The compiled formats' parts are in the table `postal_code_format_parts` (GB, US, CA, IE, BR); FR, CZ and LU have none.
- `add_country_template()` runs the ambiguity check and relabels or versions as above.
- Additive: a 2.1.0 upgrade script, no change to stored values or the binary format. Rehearsed on a fresh copy of
  production: 123 ms including the 29 built-in relabels, 21 million postcodes unchanged. Dump and restore tested with
  named patterns.
- `postal_code_pattern_check()` returns the regex as before (names included).

## The GB naming problem

The UK vocabulary is used two ways in this project, and they clash:

| Word | `to_char(pc, ...)` (a piece of text) | `district(pc)`, `outcode(pc)`, `% 'LS24'`, Royal Mail (everything up to and including it) |
|---|---|---|
| area | `A` = `EC` | `EC` |
| district | `D` = `4Y` | `EC4Y` |
| sector | `S` = `0` | `EC4Y 0` |
| walk / unit | `W` = `HQ` | `EC4Y 0HQ` |

So `part(code, 'district')` could mean `4Y` or `EC4Y`. The parts mechanism returns pieces, which is the
`to_char` meaning; the other is what an analyst expects from Royal Mail's own terms and from `district()`.
Options: (A) pieces named as `to_char` does, with `prefix_of(code, 'district')` giving `EC4Y`; (B) pieces named
differently from the levels; (C) nested, cumulative parts, which needs the same name allowed in two
alternative branches because an outcode-only code has no sector. Not decided.

## Decided: GB uses Option A

GB pieces are named as `to_char` names them -- `area`, `district`, `sector`, `walk` -- and Royal Mail's cumulative
levels come from `prefix_of(code, 'district')` (`EC4Y`), `prefix_of(code, 'sector')` (`EC4Y 0`) and so on. The same
word therefore means the piece in `part()` and everything up to and including it in `prefix_of()`; the docs
say so, and the `postal_code_parts` view lists the names.

The GB parts pattern is `(?<area>(?:AB|AL|...))(?<district>\d[A-Z\d]?)( (?<sector>\d)(?<walk>[A-Z]{2}))?`, the
areas taken from `areas.h`. It is deliberately **looser** than the format (the district's allowed letters depend
on whether the area has one or two letters, which needs the same name in two branches), so it is tested as:
accepts every code the format accepts, and splits each exactly as the `postcode` layout's own fields say
(`test_parts_gb.c`: 8.3 million valid codes, 0 differences; the pattern is also checked unambiguous).

**`to_char(postcode, text)` is deprecated** (documentation, `CHANGELOG.md`, and in the 2.1 upgrade script
`COMMENT ON FUNCTION to_char(postcode, text) IS 'DEPRECATED since 2.1: use part() and prefix_of() on postal_code'`).
No run-time warning. An open question: `part()` and `prefix_of()` are specified for `postal_code`; the legacy
`postcode` type (which `to_char` takes) would need the same two functions as overloads to make the deprecation
painless.

## Decided: where it goes

Named parts go into `postal_code` 2.1 (no storage change, additive upgrade script).
