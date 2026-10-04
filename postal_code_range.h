#ifndef POSTAL_CODE_RANGE_H__
#define POSTAL_CODE_RANGE_H__

#include <stdint.h>

// Shared by the encoders' range() hooks (see pc_encoder in
// postal_code_fmt.h).

static const uint32_t pc_pow10[] = { 1, 10, 100, 1000, 10000, 100000 };

// k leading digits (value p) of an n-digit decimal number cover
// [p * 10^(n-k), (p+1) * 10^(n-k)). A *hi of 10^n means "past the top of
// the number space", which the caller turns into an unbounded range.
static inline void pc_digit_prefix_bounds (uint32_t p, int k, int n, uint32_t *lo, uint32_t *hi) {
   uint32_t scale = pc_pow10[n - k];
   *lo = p * scale;
   *hi = (p + 1) * scale;
}

#endif
