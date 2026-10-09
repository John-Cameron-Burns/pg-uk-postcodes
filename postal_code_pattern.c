#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "postal_code_pattern.h"

#define NCH PC_PAT_NCHAR
#define SETW 12                                   // bytes holding 95 bits

#define LIMIT ((uint64_t) 1 << 48)                // the payload is 48 bits

typedef struct { uint8_t b[SETW]; } cset;

static inline void set_add (cset *s, int ch)      { s->b[ch >> 3] |= (uint8_t) (1u << (ch & 7)); }
static inline bool set_has (const cset *s, int ch) { return (s->b[ch >> 3] >> (ch & 7)) & 1; }

static bool fail (char *err, size_t errlen, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
#include <stdarg.h>
static bool fail (char *err, size_t errlen, const char *fmt, ...) {
   if (err && errlen) {
      va_list ap;
      va_start(ap, fmt);
      vsnprintf(err, errlen, fmt, ap);
      va_end(ap);
   }
   return false;
}

// ---- templates -> regular expressions ------------------------------------------------------------------
//   N  \d     A  [A-Z]     X  [0-9A-Z]     ' ' and '-' themselves     [ ... ]  ( ... )?   (nesting allowed)

#define MAXRE 600

typedef struct { char t[MAXRE]; int rep; } tok;

static bool tr_seq (const char **pp, char *out, size_t cap, int depth, char *err, size_t errlen) {
   tok *toks = malloc(sizeof(tok) * 64);
   int nt = 0;
   if (!toks) return fail(err, errlen, "out of memory");
   const char *p = *pp;
   bool ok = true;

   while (*p && ok) {
      char c = *p;
      char piece[MAXRE];
      if (c == ']') {
         if (depth == 0) { ok = fail(err, errlen, "\"]\" without a \"[\""); break; }
         break;
      }
      if (c == 'N')      strcpy(piece, "\\d");
      else if (c == 'A') strcpy(piece, "[A-Z]");
      else if (c == 'X') strcpy(piece, "[0-9A-Z]");
      else if (c == ' ') strcpy(piece, " ");
      else if (c == '-') strcpy(piece, "-");
      else if (c == '[') {
         char inner[MAXRE];
         const char *q = p + 1;
         if (!tr_seq(&q, inner, sizeof inner, depth + 1, err, errlen)) { ok = false; break; }
         if (*q != ']') { ok = fail(err, errlen, "missing \"]\""); break; }
         if (!*inner) { ok = fail(err, errlen, "an optional part \"[ ]\" is empty"); break; }
         snprintf(piece, sizeof piece, "(%s)?", inner);
         p = q;                                // now at the ']'
      } else {
         ok = fail(err, errlen, "a template is made of N (a digit), A (a letter), X (a digit or letter), spaces and "
                                "hyphens, and [ ] around an optional part; for anything else write a regular "
                                "expression between slashes, e.g. /\\d{3}(-\\d{2,3})?/");
         break;
      }
      if (nt >= 64) { ok = fail(err, errlen, "template is too long"); break; }
      if (nt && strcmp(toks[nt - 1].t, piece) == 0 && piece[strlen(piece) - 1] != '?') toks[nt - 1].rep++;
      else { strcpy(toks[nt].t, piece); toks[nt].rep = 1; nt++; }
      p++;
   }

   if (ok) {
      size_t n = 0;
      for (int i = 0; i < nt; i++) {
         int w = snprintf(out + n, cap - n, toks[i].rep > 1 ? "%s{%d}" : "%s", toks[i].t, toks[i].rep);
         if (w < 0 || (size_t) w >= cap - n) { ok = fail(err, errlen, "template is too long"); break; }
         n += (size_t) w;
      }
      if (ok) out[n] = '\0';
   }
   *pp = p;
   free(toks);
   return ok;
}

bool pc_pattern_resolve (const char *spec, char *regex, size_t regexlen, char *err, size_t errlen) {
   if (!spec || !*spec) return fail(err, errlen, "a pattern cannot be empty");
   size_t n = strlen(spec);

   if (spec[0] == '/') {
      if (n < 3 || spec[n - 1] != '/' || (n >= 2 && spec[n - 2] == '\\' && (n < 3 || spec[n - 3] != '\\')))
         return fail(err, errlen, "a regular expression is written between slashes: /\\d{5}/");
      if (n - 2 >= regexlen) return fail(err, errlen, "pattern is too long");
      memcpy(regex, spec + 1, n - 2);
      regex[n - 2] = '\0';
      return true;
   }

   if (spec[0] == 'C' && spec[1] == 'C')
      return fail(err, errlen, "\"CC\" is no longer needed: a country's own letters in front of a code (VG1110, AZ 1000) "
                               "are always accepted and dropped");
   const char *p = spec;
   char buf[MAXRE];
   if (!tr_seq(&p, buf, sizeof buf, 0, err, errlen)) return false;
   if (*p) return fail(err, errlen, "\"]\" without a \"[\"");
   if (!*buf) return fail(err, errlen, "a pattern cannot be empty");
   if (strlen(buf) >= regexlen) return fail(err, errlen, "pattern is too long");
   strcpy(regex, buf);
   return true;
}

// ---- regular expression -> syntax tree -------------------------------------------------------------------

enum { N_EMPTY, N_SET, N_CAT, N_ALT, N_REP, N_CAP };   // N_CAP: a named part, a=child, set=name index

typedef struct { int kind, a, b, min, max, set; } node;

typedef struct {
   const char *s;
   int         pos, end;
   node       *nodes;  int nn, capn;
   cset       *sets;   int nsets, caps;
   char       *err;    size_t errlen;
   bool        failed;
   char        names[PC_PAT_MAX_NAMES][PC_PAT_NAME_LEN];  int nnames;
} parser;

static int perr (parser *ps, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static int perr (parser *ps, const char *fmt, ...) {
   if (!ps->failed && ps->err && ps->errlen) {
      va_list ap;
      va_start(ap, fmt);
      vsnprintf(ps->err, ps->errlen, fmt, ap);
      va_end(ap);
   }
   ps->failed = true;
   return -1;
}

static int newnode (parser *ps, int kind, int a, int b, int min, int max, int set) {
   if (ps->nn == ps->capn) {
      ps->capn = ps->capn ? ps->capn * 2 : 64;
      node *t = realloc(ps->nodes, sizeof(node) * (size_t) ps->capn);
      if (!t) return perr(ps, "out of memory");
      ps->nodes = t;
   }
   node *n = &ps->nodes[ps->nn];
   n->kind = kind; n->a = a; n->b = b; n->min = min; n->max = max; n->set = set;
   return ps->nn++;
}

static int internset (parser *ps, const cset *s) {
   for (int i = 0; i < ps->nsets; i++) if (memcmp(&ps->sets[i], s, sizeof *s) == 0) return i;
   if (ps->nsets == ps->caps) {
      ps->caps = ps->caps ? ps->caps * 2 : 16;
      cset *t = realloc(ps->sets, sizeof(cset) * (size_t) ps->caps);
      if (!t) return perr(ps, "out of memory");
      ps->sets = t;
   }
   ps->sets[ps->nsets] = *s;
   return ps->nsets++;
}

static inline int peek (const parser *ps) { return ps->pos < ps->end ? (unsigned char) ps->s[ps->pos] : -1; }

static int parse_alt (parser *ps, int depth);

static bool class_char (parser *ps, int c) {
   if (c < PC_PAT_FIRST || c > 0x7E) { perr(ps, "only printable ASCII characters are allowed"); return false; }
   if (c >= 'a' && c <= 'z') { perr(ps, "write letters in upper case (codes are upper case; input is folded before matching)"); return false; }
   return true;
}

static int parse_class (parser *ps) {                          // after '['
   cset s;
   memset(&s, 0, sizeof s);
   bool negate = false;
   if (peek(ps) == '^') { negate = true; ps->pos++; }
   bool any = false;

   while (peek(ps) != ']') {
      if (peek(ps) < 0) return perr(ps, "missing \"]\"");
      int lo = (unsigned char) ps->s[ps->pos++];
      if (lo == '\\') {
         int e = peek(ps);
         if (e < 0) return perr(ps, "a pattern cannot end with a backslash");
         ps->pos++;
         if (e == 'd') { for (int d = '0'; d <= '9'; d++) set_add(&s, d - PC_PAT_FIRST); any = true; continue; }
         if (e >= 'a' && e <= 'z') return perr(ps, "unsupported escape \\%c (use \\d, or write the class out)", e);
         lo = e;
      }
      if (!class_char(ps, lo)) return -1;
      int hi = lo;
      if (peek(ps) == '-' && ps->pos + 1 < ps->end && ps->s[ps->pos + 1] != ']') {
         ps->pos++;
         hi = (unsigned char) ps->s[ps->pos++];
         if (hi == '\\') { hi = peek(ps); if (hi < 0) return perr(ps, "a pattern cannot end with a backslash"); ps->pos++; }
         if (!class_char(ps, hi)) return -1;
         if (hi < lo) return perr(ps, "the range %c-%c runs backwards", lo, hi);
      }
      for (int c = lo; c <= hi; c++) set_add(&s, c - PC_PAT_FIRST);
      any = true;
   }
   ps->pos++;                                                   // the ']'
   if (!any) return perr(ps, "a character class cannot be empty");
   if (negate) {
      cset n;
      memset(&n, 0, sizeof n);
      for (int c = 0; c < NCH; c++) if (!set_has(&s, c)) set_add(&n, c);
      s = n;
   }
   int si = internset(ps, &s);
   return si < 0 ? -1 : newnode(ps, N_SET, 0, 0, 0, 0, si);
}

static bool has_cap (const parser *ps, int n) {
   const node *nd = &ps->nodes[n];
   switch (nd->kind) {
   case N_CAP: return true;
   case N_CAT: case N_ALT: return has_cap(ps, nd->a) || has_cap(ps, nd->b);
   case N_REP: return has_cap(ps, nd->a);
   }
   return false;
}

static bool nullable (const parser *ps, int n) {
   const node *nd = &ps->nodes[n];
   switch (nd->kind) {
   case N_EMPTY: return true;
   case N_CAT:   return nullable(ps, nd->a) && nullable(ps, nd->b);
   case N_ALT:   return nullable(ps, nd->a) || nullable(ps, nd->b);
   case N_REP:   return nd->min == 0 || nullable(ps, nd->a);
   case N_CAP:   return nullable(ps, nd->a);
   }
   return false;
}

// after "(?<": a name, [a-z][a-z0-9_]*, then ">". Returns its index.
static int parse_name (parser *ps) {
   char name[PC_PAT_NAME_LEN];
   int n = 0;
   while (peek(ps) >= 0 && peek(ps) != '>') {
      int c = peek(ps);
      bool ok = (c >= 'a' && c <= 'z') || (n > 0 && ((c >= '0' && c <= '9') || c == '_'));
      if (!ok) return perr(ps, "a part name is a lower case letter followed by lower case letters, digits or _");
      if (n >= PC_PAT_NAME_LEN - 1) return perr(ps, "a part name is at most %d characters", PC_PAT_NAME_LEN - 1);
      name[n++] = (char) c;
      ps->pos++;
   }
   if (peek(ps) != '>') return perr(ps, "missing \">\" after the part name");
   ps->pos++;
   name[n] = '\0';
   if (!n) return perr(ps, "a part needs a name: (?<name>...)");
   for (int i = 0; i < ps->nnames; i++)
      if (strcmp(ps->names[i], name) == 0) return perr(ps, "the part name \"%s\" is used twice", name);
   if (ps->nnames >= PC_PAT_MAX_NAMES) return perr(ps, "a pattern has at most %d named parts", PC_PAT_MAX_NAMES);
   strcpy(ps->names[ps->nnames], name);
   return ps->nnames++;
}

static int parse_atom (parser *ps, int depth) {
   int c = peek(ps);
   if (c == '(') {
      ps->pos++;
      int cap = -1;
      if (peek(ps) == '?') {
         if (ps->pos + 1 < ps->end && ps->s[ps->pos + 1] == ':') ps->pos += 2;
         else if (ps->pos + 1 < ps->end && ps->s[ps->pos + 1] == '<') {
            if (ps->pos + 2 < ps->end && (ps->s[ps->pos + 2] == '=' || ps->s[ps->pos + 2] == '!'))
               return perr(ps, "lookbehind is not supported; a named part is written (?<name>...)");
            ps->pos += 2;
            cap = parse_name(ps);
            if (cap < 0) return -1;
         }
         else return perr(ps, "only (?: ) grouping and (?<name> ) named parts are supported, not lookahead or other (?...) forms");
      }
      int n = parse_alt(ps, depth + 1);
      if (n < 0) return -1;
      if (peek(ps) != ')') return perr(ps, "missing \")\"");
      ps->pos++;
      if (cap >= 0) {
         if (nullable(ps, n)) return perr(ps, "the part \"%s\" can match nothing; a named part must match at least one character", ps->names[cap]);
         n = newnode(ps, N_CAP, n, 0, 0, 0, cap);
      }
      return n;
   }
   if (c == '[') { ps->pos++; return parse_class(ps); }
   if (c == '.') return perr(ps, "\".\" is not allowed: write the characters out as a class, e.g. [0-9A-Z]");
   if (c == '*' || c == '+') return perr(ps, "\"%c\" would allow codes of any length; use {m,n} (at most %d)", c, PC_PAT_MAX_LEN);
   if (c == '?' || c == '{') return perr(ps, "nothing to repeat before \"%c\"", c);
   if (c == '^' || c == '$') return perr(ps, "\"%c\" is only allowed at the very start or end", c);
   if (c == ')') return perr(ps, "\")\" without a \"(\"");
   if (c == '\\') {
      ps->pos++;
      int e = peek(ps);
      if (e < 0) return perr(ps, "a pattern cannot end with a backslash");
      ps->pos++;
      cset s;
      memset(&s, 0, sizeof s);
      if (e == 'd') { for (int d = '0'; d <= '9'; d++) set_add(&s, d - PC_PAT_FIRST); }
      else if (strchr("()[]{}|?*+.^$\\/-", e)) set_add(&s, e - PC_PAT_FIRST);
      else return perr(ps, "unsupported escape \\%c (use \\d, or write the class out)", e);
      int si = internset(ps, &s);
      return si < 0 ? -1 : newnode(ps, N_SET, 0, 0, 0, 0, si);
   }
   ps->pos++;
   if (!class_char(ps, c)) return -1;
   cset s;
   memset(&s, 0, sizeof s);
   set_add(&s, c - PC_PAT_FIRST);
   int si = internset(ps, &s);
   return si < 0 ? -1 : newnode(ps, N_SET, 0, 0, 0, 0, si);
}

static int parse_number (parser *ps) {
   if (peek(ps) < '0' || peek(ps) > '9') return perr(ps, "expected a number in {...}");
   int v = 0;
   while (peek(ps) >= '0' && peek(ps) <= '9') {
      v = v * 10 + (ps->s[ps->pos++] - '0');
      if (v > PC_PAT_MAX_LEN) return perr(ps, "a repeat count is at most %d", PC_PAT_MAX_LEN);
   }
   return v;
}

static int parse_quant (parser *ps, int atom) {
   for (;;) {
      int c = peek(ps);
      if (c == '?') { ps->pos++; atom = newnode(ps, N_REP, atom, 0, 0, 1, 0); }
      else if (c == '{') {
         ps->pos++;
         int lo = parse_number(ps);
         if (lo < 0) return -1;
         int hi = lo;
         if (peek(ps) == ',') {
            ps->pos++;
            if (peek(ps) == '}') return perr(ps, "{%d,} would allow codes of any length; give an upper bound", lo);
            hi = parse_number(ps);
            if (hi < 0) return -1;
         }
         if (peek(ps) != '}') return perr(ps, "missing \"}\"");
         ps->pos++;
         if (hi < lo) return perr(ps, "{%d,%d}: the maximum is below the minimum", lo, hi);
         if (hi == 0) return perr(ps, "{0} repeats nothing");
         if (hi > 1 && has_cap(ps, atom)) return perr(ps, "a named part cannot be repeated (it would match more than once); only ? is allowed on it");
         atom = newnode(ps, N_REP, atom, 0, lo, hi, 0);
      }
      else if (c == '*' || c == '+') return perr(ps, "\"%c\" would allow codes of any length; use {m,n} (at most %d)", c, PC_PAT_MAX_LEN);
      else return atom;
      if (atom < 0) return -1;
   }
}

static int parse_cat (parser *ps, int depth) {
   int result = -1;
   for (;;) {
      int c = peek(ps);
      if (c < 0 || c == '|' || c == ')') break;
      int a = parse_atom(ps, depth);
      if (a < 0) return -1;
      a = parse_quant(ps, a);
      if (a < 0) return -1;
      if (result < 0) result = a;
      else { result = newnode(ps, N_CAT, result, a, 0, 0, 0); if (result < 0) return -1; }
   }
   return result < 0 ? newnode(ps, N_EMPTY, 0, 0, 0, 0, 0) : result;
}

static int parse_alt (parser *ps, int depth) {
   if (depth > 30) return perr(ps, "groups are nested too deeply");
   int left = parse_cat(ps, depth);
   if (left < 0) return -1;
   while (peek(ps) == '|') {
      ps->pos++;
      int right = parse_cat(ps, depth);
      if (right < 0) return -1;
      left = newnode(ps, N_ALT, left, right, 0, 0, 0);
      if (left < 0) return -1;
   }
   return left;
}

// ---- syntax tree -> NFA ------------------------------------------------------------------------------------

typedef struct { int8_t kind; int set, out, out1; } nstate;        // kind 0: a character; 1: either of two; 2: match;
                                                                   // 3, 4: a named part (index in set) starts / ends -- no input consumed

typedef struct { nstate *st; int n, cap; bool failed; } nfa;

#define MAX_NFA 60000

static int nnew (nfa *f, int kind, int set, int out, int out1) {
   if (f->n >= MAX_NFA) { f->failed = true; return 0; }
   if (f->n == f->cap) {
      f->cap = f->cap ? f->cap * 2 : 256;
      nstate *t = realloc(f->st, sizeof(nstate) * (size_t) f->cap);
      if (!t) { f->failed = true; return 0; }
      f->st = t;
   }
   f->st[f->n].kind = (int8_t) kind;
   f->st[f->n].set = set;
   f->st[f->n].out = out;
   f->st[f->n].out1 = out1;
   return f->n++;
}

// Builds, from the end: the fragment for `n` that continues to `next`. Returns its first state.
static int build (nfa *f, const node *nodes, int n, int next) {
   if (f->failed) return 0;
   const node *nd = &nodes[n];
   switch (nd->kind) {
   case N_EMPTY: return next;
   case N_SET:   return nnew(f, 0, nd->set, next, -1);
   case N_CAT:   { int b = build(f, nodes, nd->b, next); return build(f, nodes, nd->a, b); }
   case N_ALT:   { int a = build(f, nodes, nd->a, next), b = build(f, nodes, nd->b, next); return nnew(f, 1, 0, a, b); }
   case N_CAP:   { int cl = nnew(f, 4, nd->set, next, -1); int ch = build(f, nodes, nd->a, cl); return nnew(f, 3, nd->set, ch, -1); }
   case N_REP:   {
      int cur = next;
      for (int i = 0; i < nd->max - nd->min; i++) {                // the optional copies, innermost first
         int inner = build(f, nodes, nd->a, cur);
         cur = nnew(f, 1, 0, inner, next);
      }
      for (int i = 0; i < nd->min; i++) cur = build(f, nodes, nd->a, cur);
      return cur;
   }
   }
   return next;
}

// ---- NFA -> DFA --------------------------------------------------------------------------------------------

typedef struct {
   const nfa   *f;
   int         *stamp;  int curstamp;
   int         *stack;
} closure_ctx;

// adds to out[] (as a set) every character-state and the match state reachable from s through "either of" states
static void closure (closure_ctx *c, int s, int *out, int *nout) {
   int sp = 0;
   c->stack[sp++] = s;
   while (sp) {
      int x = c->stack[--sp];
      if (c->stamp[x] == c->curstamp) continue;
      c->stamp[x] = c->curstamp;
      const nstate *st = &c->f->st[x];
      if (st->kind == 1) { c->stack[sp++] = st->out; c->stack[sp++] = st->out1; }
      else if (st->kind == 3 || st->kind == 4) c->stack[sp++] = st->out;          // a named part's edge: a pass-through
      else out[(*nout)++] = x;
   }
}

static int cmp_int (const void *a, const void *b) { int x = *(const int *) a, y = *(const int *) b; return (x > y) - (x < y); }

typedef struct { int *pool; int npool, cappool; int *off, *len; int ns, capns; int *table; int tsize; } dfa_build;

static int intern_state (dfa_build *d, int *key, int nk, bool *failed) {
   uint32_t h = 2166136261u;
   for (int i = 0; i < nk; i++) { h ^= (uint32_t) key[i]; h *= 16777619u; }
   uint32_t idx = h % (uint32_t) d->tsize;
   while (d->table[idx] >= 0) {
      int s = d->table[idx];
      if (d->len[s] == nk && memcmp(&d->pool[d->off[s]], key, sizeof(int) * (size_t) nk) == 0) return s;
      idx = (idx + 1) % (uint32_t) d->tsize;
   }
   if (d->ns >= PC_PAT_MAX_STATES) { *failed = true; return 0; }
   if (d->ns == d->capns) {
      d->capns = d->capns ? d->capns * 2 : 64;
      d->off = realloc(d->off, sizeof(int) * (size_t) d->capns);
      d->len = realloc(d->len, sizeof(int) * (size_t) d->capns);
   }
   if (d->npool + nk > d->cappool) {
      d->cappool = (d->npool + nk) * 2 + 256;
      d->pool = realloc(d->pool, sizeof(int) * (size_t) d->cappool);
   }
   if (!d->off || !d->len || !d->pool) { *failed = true; return 0; }
   d->off[d->ns] = d->npool;
   d->len[d->ns] = nk;
   memcpy(&d->pool[d->npool], key, sizeof(int) * (size_t) nk);
   d->npool += nk;
   d->table[idx] = d->ns;
   return d->ns++;
}

// ---- compile -------------------------------------------------------------------------------------------------

static bool count_states (int s, int ns, const int16_t *next, const uint8_t *acc, uint64_t *cnt, uint8_t *mark, bool *toobig) {
   if (mark[s] == 2) return true;
   if (mark[s] == 1) return false;                              // a cycle: cannot happen without * or +
   mark[s] = 1;
   uint64_t total = acc[s];
   for (int c = 0; c < NCH; c++) {
      int t = next[(size_t) s * NCH + c];
      if (t < 0) continue;
      if (!count_states(t, ns, next, acc, cnt, mark, toobig)) return false;
      total += cnt[t];
      if (total > LIMIT) { *toobig = true; total = LIMIT + 1; }
   }
   cnt[s] = total;
   mark[s] = 2;
   return true;
}

pc_pattern *pc_pattern_compile (const char *regex, pc_alloc_fn alloc, char *err, size_t errlen) {
   parser ps;
   memset(&ps, 0, sizeof ps);
   ps.s = regex; ps.err = err; ps.errlen = errlen;
   ps.end = (int) strlen(regex);
   if (ps.end == 0) { fail(err, errlen, "a pattern cannot be empty"); return NULL; }
   if (regex[0] == '^') ps.pos = 1;
   if (ps.end > ps.pos && regex[ps.end - 1] == '$' && (ps.end < 2 || regex[ps.end - 2] != '\\')) ps.end--;

   pc_pattern *result = NULL;
   nfa f;
   memset(&f, 0, sizeof f);
   dfa_build d;
   memset(&d, 0, sizeof d);
   int16_t *next = NULL;
   uint8_t *acc = NULL, *mark = NULL;
   uint64_t *cnt = NULL;
   int *stamp = NULL, *stack = NULL, *key = NULL, *tmp = NULL;

   int root = parse_alt(&ps, 0);
   if (root >= 0 && ps.pos != ps.end) root = perr(&ps, "\")\" without a \"(\"");
   if (root < 0) goto done;

   int match = nnew(&f, 2, 0, -1, -1);
   int start = build(&f, ps.nodes, root, match);
   if (f.failed) { fail(err, errlen, "pattern is too large"); goto done; }

   stamp = calloc((size_t) f.n, sizeof(int));
   stack = malloc(sizeof(int) * ((size_t) f.n * 2 + 8));
   key   = malloc(sizeof(int) * ((size_t) f.n + 8));
   tmp   = malloc(sizeof(int) * ((size_t) f.n + 8));
   d.tsize = PC_PAT_MAX_STATES * 4;
   d.table = malloc(sizeof(int) * (size_t) d.tsize);
   next = malloc(sizeof(int16_t) * (size_t) PC_PAT_MAX_STATES * NCH);
   acc  = calloc(PC_PAT_MAX_STATES, 1);
   if (!stamp || !stack || !key || !tmp || !d.table || !next || !acc) { fail(err, errlen, "out of memory"); goto done; }
   for (int i = 0; i < d.tsize; i++) d.table[i] = -1;

   closure_ctx cc = { &f, stamp, 0, stack };
   int nk = 0;
   cc.curstamp = 1;
   closure(&cc, start, key, &nk);
   qsort(key, (size_t) nk, sizeof(int), cmp_int);
   bool bad = false;
   intern_state(&d, key, nk, &bad);

   for (int s = 0; s < d.ns && !bad; s++) {
      const int *ks = &d.pool[d.off[s]];
      int nks = d.len[s];
      for (int i = 0; i < nks; i++) if (f.st[ks[i]].kind == 2) acc[s] = 1;
      for (int c = 0; c < NCH && !bad; c++) {
         int nt = 0;
         cc.curstamp++;
         for (int i = 0; i < nks; i++) {
            const nstate *q = &f.st[ks[i]];
            if (q->kind == 0 && set_has(&ps.sets[q->set], c)) closure(&cc, q->out, tmp, &nt);
         }
         if (!nt) { next[(size_t) s * NCH + c] = -1; continue; }
         qsort(tmp, (size_t) nt, sizeof(int), cmp_int);
         int t = intern_state(&d, tmp, nt, &bad);
         next[(size_t) s * NCH + c] = (int16_t) t;
      }
   }
   if (bad) { fail(err, errlen, "pattern is too complex (more than %d states)", PC_PAT_MAX_STATES); goto done; }

   int ns = d.ns;
   cnt = calloc((size_t) ns, sizeof(uint64_t));
   mark = calloc((size_t) ns, 1);
   if (!cnt || !mark) { fail(err, errlen, "out of memory"); goto done; }
   bool toobig = false;
   if (!count_states(0, ns, next, acc, cnt, mark, &toobig)) { fail(err, errlen, "pattern allows codes of unbounded length"); goto done; }
   if (toobig || cnt[0] > LIMIT) { fail(err, errlen, "pattern allows more than 2^48 codes, which will not fit in the 48 bits a code has"); goto done; }
   if (acc[0]) { fail(err, errlen, "pattern matches the empty string"); goto done; }
   if (cnt[0] == 0) { fail(err, errlen, "pattern matches nothing"); goto done; }

   // drop edges into states from which no code can be completed
   for (int s = 0; s < ns; s++)
      for (int c = 0; c < NCH; c++) {
         int t = next[(size_t) s * NCH + c];
         if (t >= 0 && cnt[t] == 0) next[(size_t) s * NCH + c] = -1;
      }

   // longest code, by dynamic programming over the (acyclic) automaton
   int *longest = calloc((size_t) ns, sizeof(int));
   uint8_t *done_l = calloc((size_t) ns, 1);
   if (!longest || !done_l) { free(longest); free(done_l); fail(err, errlen, "out of memory"); goto done; }
   {
      // iterate to a fixed point: depth is at most PC_PAT_MAX_LEN + 1 before it must stop growing
      bool changed = true;
      int rounds = 0;
      while (changed && rounds++ <= PC_PAT_MAX_LEN + 2) {
         changed = false;
         for (int s = 0; s < ns; s++)
            for (int c = 0; c < NCH; c++) {
               int t = next[(size_t) s * NCH + c];
               if (t >= 0 && longest[t] + 1 > longest[s]) { longest[s] = longest[t] + 1; changed = true; }
            }
      }
      (void) done_l;
   }
   int maxlen = longest[0];
   free(longest); free(done_l);
   if (maxlen > PC_PAT_MAX_LEN) { fail(err, errlen, "a code may be at most %d characters long; this pattern allows %d", PC_PAT_MAX_LEN, maxlen); goto done; }

   // assemble the result in one piece: header, then the arrays largest-alignment first
   size_t nb = (size_t) ns * (NCH + 1) * sizeof(uint64_t);
   size_t nc = (size_t) ns * sizeof(uint64_t);
   size_t nn = (size_t) ns * NCH * sizeof(int16_t);
   size_t na = (size_t) ns;
   size_t total = sizeof(pc_pattern) + nb + nc + nn + na + 16;
   char *blk = alloc(total);
   if (!blk) { fail(err, errlen, "out of memory"); goto done; }
   pc_pattern *p = (pc_pattern *) blk;
   char *q = blk + ((sizeof(pc_pattern) + 7) & ~(size_t) 7);
   p->before = (uint64_t *) q; q += nb;
   p->count  = (uint64_t *) q; q += nc;
   p->next   = (int16_t *) q;  q += nn;
   p->accept = (uint8_t *) q;
   p->nstates = ns;
   p->maxlen = maxlen;
   p->total = cnt[0];
   p->has_outcode = false;
   memcpy(p->next, next, nn);
   memcpy(p->accept, acc, na);
   memcpy(p->count, cnt, nc);
   for (int s = 0; s < ns; s++) {
      uint64_t run = 0;
      for (int c = 0; c < NCH; c++) {
         p->before[(size_t) s * (NCH + 1) + c] = run;
         int t = p->next[(size_t) s * NCH + c];
         if (t >= 0) { run += cnt[t]; if (acc[s]) p->has_outcode = true; }
      }
      p->before[(size_t) s * (NCH + 1) + NCH] = run;
   }
   result = p;

done:
   free(ps.nodes); free(ps.sets); free(f.st); free(d.pool); free(d.off); free(d.len); free(d.table);
   free(next); free(acc); free(mark); free(cnt); free(stamp); free(stack); free(key); free(tmp);
   return result;
}

// ---- using a compiled pattern ----------------------------------------------------------------------------------

static inline int upcase (int c) { return (c >= 'a' && c <= 'z') ? c - 32 : c; }

// Walks text through the automaton, putting back a space or hyphen the pattern wants and the text left out.
// Returns the final state (or -1), and in *rank the number of codes that sort before the text's first code.
static int walk (const pc_pattern *p, const char *text, uint64_t *rank) {
   int s = 0;
   uint64_t r = 0;
   for (const char *t = text; *t; t++) {
      int c = upcase((unsigned char) *t);
      if (c < PC_PAT_FIRST || c > 0x7E) return -1;
      int ci = c - PC_PAT_FIRST;
      int nx = p->next[(size_t) s * NCH + ci];
      if (nx < 0) {
         bool found = false;
         for (int k = 0; k < 2 && !found; k++) {
            int sep = k ? '-' : ' ';
            if (sep == c) continue;
            int u = p->next[(size_t) s * NCH + (sep - PC_PAT_FIRST)];
            if (u >= 0 && p->next[(size_t) u * NCH + ci] >= 0) {
               r += p->accept[s] + p->before[(size_t) s * (NCH + 1) + (sep - PC_PAT_FIRST)];
               s = u;
               nx = p->next[(size_t) s * NCH + ci];
               found = true;
            }
         }
         if (!found) return -1;
      }
      r += p->accept[s] + p->before[(size_t) s * (NCH + 1) + ci];
      s = nx;
   }
   *rank = r;
   return s;
}

bool pc_pattern_parse (const pc_pattern *p, const char *text, uint64_t *rank) {
   if (!text || !*text) return false;
   uint64_t r;
   int s = walk(p, text, &r);
   if (s < 0 || !p->accept[s]) return false;
   *rank = r;
   return true;
}

int pc_pattern_render (const pc_pattern *p, uint64_t rank, char *buf) {
   if (rank >= p->total) return -1;
   int s = 0, n = 0;
   uint64_t q = rank;
   for (;;) {
      if (p->accept[s]) {
         if (q == 0) { buf[n] = '\0'; return n; }
         q--;
      }
      bool moved = false;
      for (int c = 0; c < NCH; c++) {
         int t = p->next[(size_t) s * NCH + c];
         if (t < 0) continue;
         if (q < p->count[t]) {
            if (n >= PC_PAT_MAX_LEN) return -1;
            buf[n++] = (char) (c + PC_PAT_FIRST);
            s = t;
            moved = true;
            break;
         }
         q -= p->count[t];
      }
      if (!moved) return -1;
   }
}

bool pc_pattern_valid (const pc_pattern *p, uint64_t rank) {
   return rank < p->total;
}

bool pc_pattern_range (const pc_pattern *p, const char *prefix, uint64_t *lo, uint64_t *hi, bool *unbounded) {
   if (!prefix || !*prefix) return false;
   uint64_t r;
   int s = walk(p, prefix, &r);
   if (s < 0 || p->count[s] == 0) return false;
   *lo = r;
   uint64_t end = r + p->count[s];
   *unbounded = end >= p->total;
   if (!*unbounded) *hi = end;
   return true;
}

uint64_t pc_pattern_outcode (const pc_pattern *p, uint64_t rank) {
   char buf[PC_PAT_MAX_LEN + 2];
   if (pc_pattern_render(p, rank, buf) < 0) return rank;
   int n = (int) strlen(buf);

   // walk the code again; the first proper prefix that is itself a code is the one wanted
   int s = 0;
   uint64_t r = 0;
   for (int i = 0; i < n; i++) {
      if (i > 0 && p->accept[s]) return r;
      int ci = (unsigned char) buf[i] - PC_PAT_FIRST;
      r += p->accept[s] + p->before[(size_t) s * (NCH + 1) + ci];
      s = p->next[(size_t) s * NCH + ci];
   }
   return rank;
}

// ---- named parts -------------------------------------------------------------------------------------------------

struct pc_parts {
   int     nnames;
   char    names[PC_PAT_MAX_NAMES][PC_PAT_NAME_LEN];
   int     nstates, nsets, start;
   nstate *st;
   cset   *sets;
};

pc_parts *pc_parts_compile (const char *regex, pc_alloc_fn alloc, char *err, size_t errlen) {
   parser ps;
   memset(&ps, 0, sizeof ps);
   ps.s = regex; ps.err = err; ps.errlen = errlen;
   ps.end = (int) strlen(regex);
   if (ps.end == 0) { fail(err, errlen, "a pattern cannot be empty"); return NULL; }
   if (regex[0] == '^') ps.pos = 1;
   if (ps.end > ps.pos && regex[ps.end - 1] == '$' && (ps.end < 2 || regex[ps.end - 2] != '\\')) ps.end--;

   pc_parts *result = NULL;
   nfa f;
   memset(&f, 0, sizeof f);
   int root = parse_alt(&ps, 0);
   if (root >= 0 && ps.pos != ps.end) root = perr(&ps, "\")\" without a \"(\"");
   if (root >= 0) {
      int match = nnew(&f, 2, 0, -1, -1);
      int start = build(&f, ps.nodes, root, match);
      if (f.failed) fail(err, errlen, "pattern is too large");
      else {
         pc_parts *r = alloc(sizeof *r);
         nstate *st = alloc(sizeof(nstate) * (size_t) f.n);
         cset *sets = alloc(sizeof(cset) * (size_t) (ps.nsets ? ps.nsets : 1));
         if (!r || !st || !sets) fail(err, errlen, "out of memory");
         else {
            memcpy(st, f.st, sizeof(nstate) * (size_t) f.n);
            if (ps.nsets) memcpy(sets, ps.sets, sizeof(cset) * (size_t) ps.nsets);
            r->nnames = ps.nnames;
            memcpy(r->names, ps.names, sizeof r->names);
            r->nstates = f.n; r->nsets = ps.nsets; r->start = start; r->st = st; r->sets = sets;
            result = r;
         }
      }
   }
   free(ps.nodes); free(ps.sets); free(f.st);
   return result;
}

int pc_parts_count (const pc_parts *p) { return p->nnames; }
const char *pc_parts_name (const pc_parts *p, int i) { return p->names[i]; }

#define PARTS_MAX_STEPS 200000

typedef struct {
   const pc_parts *p;
   const char     *text;
   int             len;
   int             s[PC_PAT_MAX_NAMES], e[PC_PAT_MAX_NAMES];
   int             fs[PC_PAT_MAX_NAMES], fe[PC_PAT_MAX_NAMES];
   bool            all, have_first, ambiguous, blown;
   long            steps;
} mctx;

// Backtracking over the NFA, which already lists the preferred branch first (the first of an alternation,
// the taken branch of an optional or repeated part). In `all` mode it explores every way to match instead.
static bool nm (mctx *m, int s, int pos) {
   if (++m->steps > PARTS_MAX_STEPS) { m->blown = true; return true; }
   const nstate *q = &m->p->st[s];
   switch (q->kind) {
   case 0: {
      if (pos >= m->len) return false;
      int c = upcase((unsigned char) m->text[pos]) - PC_PAT_FIRST;
      if (c < 0 || c >= NCH || !set_has(&m->p->sets[q->set], c)) return false;
      return nm(m, q->out, pos + 1);
   }
   case 1: return nm(m, q->out, pos) || nm(m, q->out1, pos);
   case 2:
      if (pos != m->len) return false;
      if (!m->all) return true;
      if (!m->have_first) {
         memcpy(m->fs, m->s, sizeof m->s); memcpy(m->fe, m->e, sizeof m->e);
         m->have_first = true;
      }
      else if (memcmp(m->fs, m->s, sizeof m->s) || memcmp(m->fe, m->e, sizeof m->e)) m->ambiguous = true;
      return m->ambiguous;
   case 3: {
      int os = m->s[q->set], oe = m->e[q->set];
      m->s[q->set] = pos; m->e[q->set] = -1;
      if (nm(m, q->out, pos)) return true;
      m->s[q->set] = os; m->e[q->set] = oe;
      return false;
   }
   case 4: {
      int oe = m->e[q->set];
      m->e[q->set] = pos;
      if (nm(m, q->out, pos)) return true;
      m->e[q->set] = oe;
      return false;
   }
   }
   return false;
}

static void mctx_init (mctx *m, const pc_parts *p, const char *text, bool all) {
   memset(m, 0, sizeof *m);
   m->p = p; m->text = text; m->len = (int) strlen(text); m->all = all;
   for (int i = 0; i < PC_PAT_MAX_NAMES; i++) m->s[i] = m->e[i] = m->fs[i] = m->fe[i] = -1;
}

int pc_parts_match (const pc_parts *p, const char *text, int *start, int *end) {
   mctx m;
   mctx_init(&m, p, text, false);
   bool ok = nm(&m, p->start, 0);
   if (m.blown) return -1;
   if (!ok) return 0;
   for (int i = 0; i < p->nnames; i++) { start[i] = m.s[i]; end[i] = m.s[i] < 0 ? -1 : m.e[i]; }
   return 1;
}

int pc_parts_ambiguous (const pc_parts *p, const char *text) {
   mctx m;
   mctx_init(&m, p, text, true);
   nm(&m, p->start, 0);
   if (m.blown) return -1;
   return m.ambiguous ? 1 : 0;
}

void pc_pattern_strip_names (const char *regex, char *out) {
   bool in_class = false;
   const char *r = regex;
   char *o = out;
   while (*r) {
      if (*r == '\\' && r[1]) { *o++ = *r++; *o++ = *r++; continue; }
      if (in_class) { if (*r == ']') in_class = false; *o++ = *r++; continue; }
      if (*r == '[') { in_class = true; *o++ = *r++; if (*r == '^') *o++ = *r++; if (*r == ']') *o++ = *r++; continue; }
      if (r[0] == '(' && r[1] == '?' && r[2] == '<' && r[3] != '=' && r[3] != '!') {
         const char *e = strchr(r, '>');
         if (e) { *o++ = '('; *o++ = '?'; *o++ = ':'; r = e + 1; continue; }
      }
      *o++ = *r++;
   }
   *o = '\0';
}

// ---- is the split unique? ----------------------------------------------------------------------------------------

int pc_parts_check_exhaustive (const pc_parts *p, const pc_pattern *pat, char *msg, size_t msglen) {
   if (pat->total > PC_PARTS_EXHAUSTIVE_MAX) return -1;
   char text[PC_PAT_MAX_LEN + 1];
   for (uint64_t r = 0; r < pat->total; r++) {
      if (pc_pattern_render(pat, r, text) < 0) continue;
      int a = pc_parts_ambiguous(p, text);
      if (a < 0) { snprintf(msg, msglen, "too complex to split \"%s\"", text); return -1; }
      if (a == 1) { snprintf(msg, msglen, "%s", text); return 1; }
   }
   return 0;
}

// Static analysis. A "position" is a place in the pattern between characters: a state that wants a character, or
// the match state. From a position, a character leads to the next stretch of pattern, which is walked through
// (alternatives, optional bits, part boundaries) to reach the next position; the part boundaries met on the way
// are that step's "gap". Two paths over the same text put the parts differently exactly when, at some step, their
// gaps differ. So: search pairs of positions reachable together, remembering whether the paths have already
// diverged; the pattern is ambiguous if a pair of match states is reached after diverging.

typedef struct { int pos; unsigned char n; unsigned char m[2 * PC_PAT_MAX_NAMES]; } gapent;
typedef struct { gapent *e; int n; } gaplist;

#define GAP_MAX 256

static bool gap_walk (const pc_parts *p, const int *posid, int s, gapent *cur, gaplist *out, bool *toobig, int depth) {
   if (depth > 4000) { *toobig = true; return false; }
   const nstate *q = &p->st[s];
   switch (q->kind) {
   case 0: case 2: {
      cur->pos = posid[s];
      for (int i = 0; i < out->n; i++)
         if (out->e[i].pos == cur->pos && out->e[i].n == cur->n && memcmp(out->e[i].m, cur->m, cur->n) == 0) return true;
      if (out->n >= GAP_MAX) { *toobig = true; return false; }
      out->e = realloc(out->e, sizeof(gapent) * (size_t) (out->n + 1));
      if (!out->e) { *toobig = true; return false; }
      out->e[out->n++] = *cur;
      return true;
   }
   case 1: return gap_walk(p, posid, q->out, cur, out, toobig, depth + 1) && gap_walk(p, posid, q->out1, cur, out, toobig, depth + 1);
   case 3: case 4: {
      gapent c = *cur;
      c.m[c.n++] = (unsigned char) (q->set * 2 + (q->kind == 4));
      return gap_walk(p, posid, q->out, &c, out, toobig, depth + 1);
   }
   }
   return true;
}

int pc_parts_check_static (const pc_parts *p, char *msg, size_t msglen) {
   int *posid = malloc(sizeof(int) * (size_t) p->nstates);
   int *posst = malloc(sizeof(int) * (size_t) p->nstates);
   if (!posid || !posst) { free(posid); free(posst); return -1; }
   int n = 0;
   for (int s = 0; s < p->nstates; s++) {
      posid[s] = -1;
      if (p->st[s].kind == 0 || p->st[s].kind == 2) { posid[s] = n; posst[n++] = s; }
   }
   int result = -1;
   gaplist *gaps = NULL;
   uint8_t *seen = NULL;
   int32_t *parent = NULL;
   uint8_t *pch = NULL;
   int32_t *queue = NULL;
   gaplist start = { NULL, 0 };
   if (n > PC_PARTS_STATIC_MAX_POSITIONS) goto done;

   gaps = calloc((size_t) n, sizeof *gaps);                      // the gap after consuming at each position, built on first use
   size_t cells = (size_t) n * (size_t) n * 2;
   seen = calloc((cells + 7) / 8, 1);
   parent = malloc(sizeof(int32_t) * cells);
   pch = malloc(cells);
   queue = malloc(sizeof(int32_t) * cells);
   if (!gaps || !seen || !parent || !pch || !queue) goto done;

   bool toobig = false;
   gapent z; memset(&z, 0, sizeof z);
   if (!gap_walk(p, posid, p->start, &z, &start, &toobig, 0) || toobig) goto done;

   size_t qh = 0, qt = 0;
   int found = -1;
   #define CELL(a, b, d) (((size_t) (a) * (size_t) n + (size_t) (b)) * 2 + (size_t) (d))
   #define SEEN(c) ((seen[(c) >> 3] >> ((c) & 7)) & 1)
   #define MARK(c) (seen[(c) >> 3] |= (uint8_t) (1u << ((c) & 7)))
   for (int i = 0; i < start.n; i++)
      for (int j = 0; j < start.n; j++) {
         int d = !(start.e[i].n == start.e[j].n && memcmp(start.e[i].m, start.e[j].m, start.e[i].n) == 0);
         size_t c = CELL(start.e[i].pos, start.e[j].pos, d);
         if (SEEN(c)) continue;
         MARK(c); parent[c] = -1; pch[c] = 0; queue[qt++] = (int32_t) c;
      }
   while (qh < qt && found < 0) {
      size_t c = (size_t) queue[qh++];
      int d = (int) (c & 1);
      size_t ab = c >> 1;
      int a = (int) (ab / (size_t) n), b = (int) (ab % (size_t) n);
      const nstate *qa = &p->st[posst[a]], *qb = &p->st[posst[b]];
      if (qa->kind == 2 && qb->kind == 2) { if (d) found = (int) c; continue; }
      if (qa->kind == 2 || qb->kind == 2) continue;             // one path has ended and the other has not
      int ch = -1;
      for (int k = 0; k < NCH; k++) if (set_has(&p->sets[qa->set], k) && set_has(&p->sets[qb->set], k)) { ch = k; break; }
      if (ch < 0) continue;
      if (!gaps[a].e) {
         gapent g0; memset(&g0, 0, sizeof g0);
         gaps[a].n = 0;
         if (!gap_walk(p, posid, qa->out, &g0, &gaps[a], &toobig, 0) || toobig) goto done;
      }
      if (!gaps[b].e) {
         gapent g0; memset(&g0, 0, sizeof g0);
         gaps[b].n = 0;
         if (!gap_walk(p, posid, qb->out, &g0, &gaps[b], &toobig, 0) || toobig) goto done;
      }
      for (int i = 0; i < gaps[a].n; i++)
         for (int j = 0; j < gaps[b].n; j++) {
            const gapent *x = &gaps[a].e[i], *y = &gaps[b].e[j];
            int nd = d || !(x->n == y->n && memcmp(x->m, y->m, x->n) == 0);
            size_t nc = CELL(x->pos, y->pos, nd);
            if (SEEN(nc)) continue;
            MARK(nc); parent[nc] = (int32_t) c; pch[nc] = (uint8_t) ch; queue[qt++] = (int32_t) nc;
         }
   }
   if (found < 0) { result = 0; goto done; }
   {
      char rev[PC_PAT_MAX_LEN * 4 + 8];
      int len = 0;
      for (int32_t c = found; c >= 0 && parent[c] >= 0 && len < (int) sizeof rev - 1; c = parent[c]) rev[len++] = (char) (pch[c] + PC_PAT_FIRST);
      for (int i = 0; i < len / 2; i++) { char t = rev[i]; rev[i] = rev[len - 1 - i]; rev[len - 1 - i] = t; }
      rev[len] = '\0';
      snprintf(msg, msglen, "%s", rev);
      result = 1;
   }
done:
   if (gaps) { for (int i = 0; i < n; i++) free(gaps[i].e); }
   free(gaps); free(start.e); free(seen); free(parent); free(pch); free(queue); free(posid); free(posst);
   return result;
   #undef CELL
   #undef SEEN
   #undef MARK
}

int pc_parts_check (const pc_parts *p, const pc_pattern *pat, char *msg, size_t msglen) {
   msg[0] = '\0';
   int r = pc_parts_check_exhaustive(p, pat, msg, msglen);
   if (r == 0) return PC_CHECK_UNAMBIGUOUS;
   if (r == 1) return PC_CHECK_AMBIGUOUS;
   r = pc_parts_check_static(p, msg, msglen);
   if (r == 0) return PC_CHECK_UNAMBIGUOUS;
   if (r == 1) return PC_CHECK_AMBIGUOUS;
   uint64_t n = PC_PARTS_SAMPLE, step = pat->total / n ? pat->total / n : 1, done = 0;
   char text[PC_PAT_MAX_LEN + 1];
   for (uint64_t k = 0, rk = 0; k < n && rk < pat->total; k++, rk += step) {
      if (pc_pattern_render(pat, rk, text) < 0) continue;
      done++;
      if (pc_parts_ambiguous(p, text) == 1) { snprintf(msg, msglen, "%s", text); return PC_CHECK_AMBIGUOUS; }
   }
   snprintf(msg, msglen, "checked %llu of %llu codes", (unsigned long long) done, (unsigned long long) pat->total);
   return PC_CHECK_PARTIAL;
}
