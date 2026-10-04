#ifndef POSTAL_CODE_PATTERN_H__
#define POSTAL_CODE_PATTERN_H__

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

// Ranked patterns: a country's postal codes defined by a bounded regular expression.
//
// A pattern denotes a FINITE set of codes (there is no unbounded repetition), and a code is stored as
// its RANK -- the number of codes that sort before it, in plain text order. That one idea gives
// everything the type needs, exactly, for any pattern:
//
//   * order            the numbers sort as the text sorts, so a coarser code sorts just before the
//                      finer ones that extend it ("SW1A" before "SW1A 1AA");
//   * validity         a number is valid if it is below the number of codes;
//   * prefix ranges    the codes that start with a given prefix are consecutive, so a prefix is one
//                      range [lo, hi), lo is the smallest code in it and hi the smallest code after it
//                      -- real codes, never a string the pattern would reject;
//   * no wasted bits   a pattern with 3,000,000,000 codes needs 32 bits however it is written.
//
// The pattern is the whole definition, so it can say what a template cannot: which letters may appear
// where, that a code may be one of several lengths or forms, that it starts with a fixed prefix, that
// 0000 is not a code.
//
// SYNTAX (a subset of POSIX extended regular expressions, upper case, ASCII):
//     literal       any printable character; \ before ( ) [ ] { } | ? * + . ^ $ \ /
//     \d            a digit            [A-Z0-9] a class (ranges, ^ to negate, \d inside)
//     X?  X{n}  X{n,m}                 optional / repeated, bounded (n, m at most 40)
//     ( ... )  (?: ... )  A|B          grouping and alternation
//     ^ $                              allowed at the very start / end, and ignored
//   Not allowed, with a message saying so: * + (unbounded), . (write a class), lookahead, back-references,
//   lower case (codes are upper case; input is folded to upper case before matching).
//
// A TEMPLATE is the short form for the simple cases: N a digit, A a letter, X a digit or letter, ' ' and
// '-' themselves, [ ... ] an optional part (nesting allowed): "NNNNN[-NNNN]" means \d{5}(-\d{4})?.
// A regular expression is written between slashes: "/\d{3}(-\d{2,3})?/".
//
// Separators (a space or hyphen the pattern has) may be left out of the input and are put back.
//
// This file is Postgres-free so the engine can be driven and tested on its own
// (test_postal_code_pattern.c).

#define PC_PAT_MAX_LEN     40        // longest code, in characters
#define PC_PAT_MAX_STATES  2048      // states in the compiled automaton
#define PC_PAT_FIRST       0x20      // the characters a code may contain: 0x20 .. 0x7E
#define PC_PAT_NCHAR       95

typedef struct {
   uint64_t  total;                  // number of codes: ranks 0 .. total-1 are valid
   int       nstates;
   int       maxlen;                 // longest code
   bool      has_outcode;            // some code is a proper prefix of another code
   int16_t  *next;                   // [nstates][PC_PAT_NCHAR]: where a character leads, -1 if nowhere
   uint8_t  *accept;                 // [nstates]: the text so far is a code
   uint64_t *count;                  // [nstates]: codes that can still be completed from this state
   uint64_t *before;                 // [nstates][PC_PAT_NCHAR + 1]: codes reached by characters smaller than c
} pc_pattern;

typedef void *(*pc_alloc_fn) (size_t);

// Turns a spec -- a template, or /regex/ -- into the regular expression it means. False and a message if
// it is neither. (The regular expression is what is stored: a stored code's meaning depends only on the
// SET of codes the pattern denotes, so it cannot be changed by how the spec is later translated.)
bool pc_pattern_resolve (const char *spec, char *regex, size_t regexlen, char *err, size_t errlen);

// Compiles a regular expression. The result is allocated in pieces with `alloc` (malloc in tests, a
// long-lived memory context in the server); nothing else is kept.
pc_pattern *pc_pattern_compile (const char *regex, pc_alloc_fn alloc, char *err, size_t errlen);

// text -> rank. Letters may be either case. False if the text is not a code.
bool pc_pattern_parse (const pc_pattern *p, const char *text, uint64_t *rank);

// rank -> text (buf holds PC_PAT_MAX_LEN + 1). Returns the length, or -1 if the rank is not valid.
int pc_pattern_render (const pc_pattern *p, uint64_t rank, char *buf);

bool pc_pattern_valid (const pc_pattern *p, uint64_t rank);

// A prefix of a code (at least one character): the ranks [lo, hi) of every code that starts with it.
// *unbounded is set instead of *hi if nothing sorts after them. False if no code starts with it.
bool pc_pattern_range (const pc_pattern *p, const char *prefix, uint64_t *lo, uint64_t *hi, bool *unbounded);

// The SHORTEST shorter code this one extends ("12345" for "12345-6789"; "100" for "100-123", which also extends
// "100-12"), or the code itself if there is none. The shortest, so that an outcode is its own outcode.
uint64_t pc_pattern_outcode (const pc_pattern *p, uint64_t rank);

#endif
