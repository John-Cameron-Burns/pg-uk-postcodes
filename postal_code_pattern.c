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

enum { N_EMPTY, N_SET, N_CAT, N_ALT, N_REP };

typedef struct { int kind, a, b, min, max, set; } node;

typedef struct {
   const char *s;
   int         pos, end;
   node       *nodes;  int nn, capn;
   cset       *sets;   int nsets, caps;
   char       *err;    size_t errlen;
   bool        failed;
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

static int parse_atom (parser *ps, int depth) {
   int c = peek(ps);
   if (c == '(') {
      ps->pos++;
      if (peek(ps) == '?') {
         if (ps->pos + 1 < ps->end && ps->s[ps->pos + 1] == ':') ps->pos += 2;
         else return perr(ps, "only (?: ) grouping is supported, not lookahead or other (?...) forms");
      }
      int n = parse_alt(ps, depth + 1);
      if (n < 0) return -1;
      if (peek(ps) != ')') return perr(ps, "missing \")\"");
      ps->pos++;
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

typedef struct { int8_t kind; int set, out, out1; } nstate;        // kind 0: a character; 1: either of two; 2: match

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
