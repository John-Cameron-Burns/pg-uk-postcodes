#include <stdio.h>
#include <string.h>

#include "postal_code_template.h"

static inline bool is_data (char k)    { return k == 'N' || k == 'A' || k == 'X'; }
static inline bool is_literal (char k) { return k == ' ' || k == '-'; }

static inline unsigned radix (char kind) {
   return kind == 'N' ? 10 : kind == 'A' ? 26 : 36;
}

// Symbol value of c under a position of this kind, or -1. Letters are
// accepted in either case.
static int sym_value (char kind, char c) {
   if (c >= 'a' && c <= 'z') c = (char) (c - 32);
   bool digit = c >= '0' && c <= '9';
   bool alpha = c >= 'A' && c <= 'Z';
   switch (kind) {
   case 'N': return digit ? c - '0' : -1;
   case 'A': return alpha ? c - 'A' : -1;
   default:  return digit ? c - '0' : alpha ? 10 + (c - 'A') : -1; // 'X'
   }
}

static char sym_char (char kind, unsigned v) {
   if (kind == 'N') return (char) ('0' + v);
   if (kind == 'A') return (char) ('A' + v);
   return v < 10 ? (char) ('0' + v) : (char) ('A' + (v - 10));
}

static bool fail (char *err, size_t errlen, const char *msg) {
   if (err && errlen) snprintf(err, errlen, "%s", msg);
   return false;
}

// a * b, or false on 64-bit overflow
static bool mul (uint64_t a, uint64_t b, uint64_t *out) {
   if (b && a > UINT64_MAX / b) return false;
   *out = a * b;
   return true;
}

bool pc_template_compile (const char *spec, pc_template *t, char *err, size_t errlen) {
   memset(t, 0, sizeof *t);
   if (!spec || !*spec) return fail(err, errlen, "a template cannot be empty");
   if (strlen(spec) > PC_TPL_MAX_ITEMS + 2) return fail(err, errlen, "template is too long");

   bool in_group = false, closed = false;
   t->tail_at = -1;

   // a leading "CC" is the country's own letters, not part of the code
   const char *start = spec;
   if (spec[0] == 'C' && spec[1] == 'C') {
      t->cc_prefix = true;
      start = spec + 2;
      if (*start == ' ' || *start == '-') start++;   // "CC NNNN", "CC-NNNN"
      if (!*start || *start == '[') return fail(err, errlen, "\"CC\" must be followed by the code itself");
   }

   // a leading optional group of letters: "[A]NNNN"
   if (*start == '[') {
      const char *g = start + 1;
      while (*g == 'A') {
         if (t->nitems >= PC_TPL_MAX_ITEMS) return fail(err, errlen, "template is too long");
         t->item[t->nitems++] = 'A';
         g++;
      }
      if (*g != ']' || g == start + 1)
         return fail(err, errlen, "a leading optional group is letters only, e.g. [A]NNNN");
      t->lead_n = t->head_from = t->nitems;
      start = g + 1;
      if (*start != 'N')
         return fail(err, errlen, "the code after a leading optional group must start with a digit (N), "
                                  "so that codes without the group sort first");
   }

   for (const char *s = start; *s; s++) {
      if (closed) return fail(err, errlen, "nothing may follow the closing \"]\"");
      char c = *s;
      if (is_data(c) || is_literal(c)) {
         if (t->nitems >= PC_TPL_MAX_ITEMS) return fail(err, errlen, "template is too long");
         if (is_literal(c)) {
            if (t->nitems == t->lead_n)
               return fail(err, errlen, "a template cannot start with a separator");
            if (is_literal(t->item[t->nitems - 1]))
               return fail(err, errlen, "two separators in a row");
            if (!in_group && (s[1] == '\0' || s[1] == '['))
               return fail(err, errlen, "a separator must be followed by a letter or digit, "
                                        "or be the first thing inside [ ]");
         }
         t->item[t->nitems++] = c;
      } else if (c == '[') {
         if (in_group) return fail(err, errlen, "only one optional group is allowed");
         if (t->nitems == t->lead_n) return fail(err, errlen, "the optional group cannot be the whole template");
         in_group = true;
         t->tail_at = t->nitems;
      } else if (c == ']') {
         if (!in_group) return fail(err, errlen, "\"]\" without \"[\"");
         if (t->nitems == t->tail_at) return fail(err, errlen, "the optional group is empty");
         closed = true;
      } else {
         return fail(err, errlen, "a template is made of N (digit), A (letter), X (digit or letter), "
                                  "separators ' ' and '-', one optional [ ] group at the end, and CC first for the country's own letters");
      }
   }
   if (in_group && !closed) return fail(err, errlen, "missing \"]\"");
   if (t->nitems == 0) return fail(err, errlen, "a template cannot be empty");

   t->has_tail = t->tail_at >= 0;
   if (!t->has_tail) t->tail_at = t->nitems;
   if (!is_data(t->item[t->nitems - 1])) return fail(err, errlen, "a template must end with a letter or digit");
   if (!is_data(t->item[t->tail_at - 1])) return fail(err, errlen, "a template cannot have a separator before the optional group");

   t->head_space = 1;
   t->tail_space = t->has_tail ? 1 : 0;
   for (int i = t->head_from; i < t->nitems; i++) {
      if (!is_data(t->item[i])) continue;
      uint64_t *space = i < t->tail_at ? &t->head_space : &t->tail_space;
      if (!mul(*space, radix(t->item[i]), space))
         return fail(err, errlen, "template does not fit in the 48 bits available");
   }

   t->mult = t->has_tail ? 1 + t->tail_space : 1;
   if (!mul(t->head_space, t->mult, &t->body))
      return fail(err, errlen, "template does not fit in the 48 bits available");
   t->total = t->body;
   if (t->lead_n) {
      t->lead_space = 1;
      for (int i = 0; i < t->lead_n; i++) t->lead_space *= 26;           // at most 40 letters would overflow: checked below
      if (t->lead_n > 8 || !mul(1 + t->lead_space, t->body, &t->total))
         return fail(err, errlen, "template does not fit in the 48 bits available");
   }
   if (t->total > ((uint64_t) 1 << PC_PAYLOAD_BITS))
      return fail(err, errlen, "template does not fit in the 48 bits available");

   snprintf(t->spec, sizeof t->spec, "%s", spec);
   return true;
}


// Matches s against positions [from, to), accumulating the data symbols as a
// mixed-radix number. A separator in the text is consumed if present and
// not needed if absent. With allow_short the text may end anywhere (a
// fragment); otherwise it must supply every data position. *count is the
// number of symbols taken, *space the product of their radices.
static bool scan (const pc_template *t, int from, int to, const char **sp, bool allow_short,
                  uint64_t *acc, int *count, uint64_t *space) {
   for (int i = from; i < to; i++) {
      char kind = t->item[i];
      if (is_literal(kind)) {
         if (**sp == kind) (*sp)++;
         continue;
      }
      if (**sp == '\0') return allow_short;
      int v = sym_value(kind, **sp);
      if (v < 0) return false;
      *acc = *acc * radix(kind) + (uint64_t) v;
      *space *= radix(kind);
      (*sp)++;
      (*count)++;
   }
   return true;
}

const char *pc_template_skip_cc (const pc_template *t, const char cc[2], const char *text) {
   if (!t->cc_prefix || !text) return text;
   char a = text[0], b = a ? text[1] : '\0';
   if (a >= 'a' && a <= 'z') a = (char) (a - 32);
   if (b >= 'a' && b <= 'z') b = (char) (b - 32);
   if (a != cc[0] || b != cc[1]) return text;
   text += 2;
   if (*text == ' ' || *text == '-') text++;
   return text;
}

bool pc_template_parse (const pc_template *t, const char *text, uint64_t *out) {
   if (!text) return false;
   const char *s = text;

   // a leading group is present exactly when the text starts with a letter (the code proper starts with a digit)
   uint64_t lead = 0;
   if (t->lead_n && ((*s >= 'A' && *s <= 'Z') || (*s >= 'a' && *s <= 'z'))) {
      uint64_t v = 0, ls = 1;
      int n = 0;
      if (!scan(t, 0, t->lead_n, &s, false, &v, &n, &ls)) return false;
      lead = 1 + v;
   }

   uint64_t head = 0, hs = 1;
   int n = 0;
   if (!scan(t, t->head_from, t->tail_at, &s, false, &head, &n, &hs)) return false;

   uint64_t base = lead * t->body;
   if (*s == '\0') { *out = base + head * t->mult; return true; }  // the head alone
   if (!t->has_tail) return false;                                 // trailing garbage

   uint64_t tail = 0, ts = 1;
   n = 0;
   if (!scan(t, t->tail_at, t->nitems, &s, false, &tail, &n, &ts) || *s != '\0') return false;
   *out = base + head * t->mult + 1 + tail;
   return true;
}

int pc_template_render (const pc_template *t, uint64_t payload, char *buf) {
   bool bad = payload >= t->total;
   uint64_t lead = bad ? 0 : payload / t->body;
   uint64_t rem  = bad ? 0 : payload % t->body;
   uint64_t head = bad ? 0 : rem / t->mult;
   uint64_t tr   = bad ? 0 : rem % t->mult;
   bool tail_present = !bad && t->has_tail && tr > 0;
   uint64_t tail = tail_present ? tr - 1 : 0;

   // peel symbols off the least significant end, so fill right to left
   for (int i = t->tail_at - 1; i >= t->head_from; i--) {
      char kind = t->item[i];
      if (is_literal(kind)) { buf[i] = kind; continue; }
      if (bad) { buf[i] = '?'; continue; }
      buf[i] = sym_char(kind, (unsigned) (head % radix(kind)));
      head /= radix(kind);
   }
   int n = t->tail_at;
   if (tail_present || (bad && t->has_tail)) {
      for (int i = t->nitems - 1; i >= t->tail_at; i--) {
         char kind = t->item[i];
         if (is_literal(kind)) { buf[i] = kind; continue; }
         if (bad) { buf[i] = '?'; continue; }
         buf[i] = sym_char(kind, (unsigned) (tail % radix(kind)));
         tail /= radix(kind);
      }
      n = t->nitems;
   }
   if (lead > 0) {                                   // the leading letters, most significant first
      uint64_t v = lead - 1;
      for (int i = t->lead_n - 1; i >= 0; i--) { buf[i] = sym_char('A', (unsigned) (v % 26)); v /= 26; }
   } else if (t->head_from) {                        // absent: the code starts at the head
      memmove(buf, buf + t->head_from, (size_t) (n - t->head_from));
      n -= t->head_from;
   }
   buf[n] = '\0';
   return n;
}

bool pc_template_valid (const pc_template *t, uint64_t payload) {
   return payload < t->total;
}

uint64_t pc_template_outcode (const pc_template *t, uint64_t payload) {
   return payload - payload % t->mult;
}

// A fragment is any prefix of the code (at least one symbol), separators
// optional. Its range:
//   - leading letters only: every code with that start, the leading group
//     being the most significant part;
//   - k symbols within the head: every head that starts with them, whatever
//     follows -- [p * rest, (p+1) * rest) heads, each head's family starting
//     at its bare form;
//   - k beyond the head (needs the optional group): that head, and the tails
//     starting with the rest -- the head's own bare form is excluded.
// Either way the range ends where the next sibling starts: the next head's
// bare form when this is the last tail, and past the end of the space (an
// unbounded range, which the caller turns into the end-of-country bound) when
// nothing follows.
bool pc_template_range (const pc_template *t, const char *fragment, uint64_t *lo, uint64_t *hi, bool *unbounded) {
   if (!fragment) return false;
   const char *s = fragment;
   uint64_t offset = 0;                            // where this leading group's block starts

   if (t->lead_n && ((*s >= 'A' && *s <= 'Z') || (*s >= 'a' && *s <= 'z'))) {
      uint64_t lv = 0, ls = 1;
      int m = 0;
      if (!scan(t, 0, t->lead_n, &s, true, &lv, &m, &ls)) return false;
      if (*s == '\0') {                            // only (part of) the leading group
         uint64_t rest = t->lead_space / ls;
         *lo = (1 + lv * rest) * t->body;
         *hi = (1 + (lv + 1) * rest) * t->body;
         *unbounded = *hi >= t->total;
         return true;
      }
      if (m != t->lead_n) return false;             // text went on, so the whole group must have been given
      offset = (1 + lv) * t->body;
   }

   uint64_t head = 0, hs = 1;
   int k = 0;
   if (!scan(t, t->head_from, t->tail_at, &s, true, &head, &k, &hs)) return false;
   if (k == 0) return false;

   // a fragment inside (or exactly at the end of) the head
   if (*s == '\0') {
      uint64_t rest = t->head_space / hs;           // exact: product of the remaining radices
      *lo = offset + head * rest * t->mult;
      *hi = offset + (head + 1) * rest * t->mult;
      *unbounded = *hi >= t->total;
      return true;
   }

   // text remains after the head symbols were all consumed (a partial head
   // always ends the text): it can only be the optional group
   if (!t->has_tail || hs != t->head_space) return false;

   uint64_t tail = 0, ts = 1;
   int m = 0;
   if (!scan(t, t->tail_at, t->nitems, &s, true, &tail, &m, &ts) || *s != '\0') return false;

   if (m == 0) {                                    // "12345-": starts with the separator, so the tails only, not the bare head
      *lo = offset + head * t->mult + 1;
      *hi = offset + (head + 1) * t->mult;
      *unbounded = *hi >= t->total;
      return true;
   }

   uint64_t rest = t->tail_space / ts;
   *lo = offset + head * t->mult + 1 + tail * rest;
   uint64_t end = (tail + 1) * rest;
   *hi = end < t->tail_space ? offset + head * t->mult + 1 + end : offset + (head + 1) * t->mult;
   *unbounded = *hi >= t->total;
   return true;
}
