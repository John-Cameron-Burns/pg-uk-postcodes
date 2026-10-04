#ifndef POSTAL_CODE_H__
#define POSTAL_CODE_H__

#include <stdint.h>
#include <stdbool.h>

// A postcode for any country, encoded in 64 bits.
//
//   63           54 53      48 47                                    0
//  +--------------+----------+--------------------------------------+
//  |  country:10  | format:6 |         national payload:48          |
//  +--------------+----------+--------------------------------------+
//
// Country occupies the *top* bits so a plain unsigned 64-bit
// comparison sorts by country first. Within a country, ordering
// falls through to format then payload -- but a country has
// exactly one format at a time in practice (see postal_code_fmt.h),
// so in-country ordering is really just whatever that format's own
// payload layout defines.
//
// 48 payload bits, not 32: a flat 32-bit national part would cover
// GB (32) and US ZIP5+ZIP4 (31), but not Iran's two 5-digit groups
// or Argentina's letter+4digit+3letter CPA, both of which need 34.
// Country (10) + format (6) only claims 16 of the top 32 bits,
// leaving 48 for payload -- comfortably above every format checked
// so far. A format simply uses as much of those 48 bits as it
// needs and leaves the rest zero; nothing here assumes a fixed
// payload width across formats.

typedef uint64_t postal_code;

#define GET_BITS64(var,pos,len) \
   (((var) >> (pos)) & (((uint64_t)1 << (len)) - 1))
#define SET_BITS64(var,pos,len,set) \
   ((var) = ((var) & ~((((uint64_t)1 << (len)) - 1) << (pos))) \
            | (((uint64_t)(set)) << (pos)))

#define PC_COUNTRY_BITS  10
#define PC_FORMAT_BITS    6
#define PC_PAYLOAD_BITS  48

#define PC_PAYLOAD_POS   0
#define PC_FORMAT_POS    PC_PAYLOAD_BITS
#define PC_COUNTRY_POS   (PC_FORMAT_POS + PC_FORMAT_BITS)

#define GET_COUNTRY(p)    GET_BITS64(p, PC_COUNTRY_POS, PC_COUNTRY_BITS)
#define GET_FORMAT(p)     GET_BITS64(p, PC_FORMAT_POS,  PC_FORMAT_BITS)
#define GET_PAYLOAD(p)    GET_BITS64(p, PC_PAYLOAD_POS, PC_PAYLOAD_BITS)

#define SET_COUNTRY(p,v)  SET_BITS64(p, PC_COUNTRY_POS, PC_COUNTRY_BITS, v)
#define SET_FORMAT(p,v)   SET_BITS64(p, PC_FORMAT_POS,  PC_FORMAT_BITS,  v)
#define SET_PAYLOAD(p,v)  SET_BITS64(p, PC_PAYLOAD_POS, PC_PAYLOAD_BITS, v)

// ---------------------------------------------------------------
// Country: packed as its own ISO 3166-1 alpha-2 letters, not as an
// index into a lookup table.
//
// Each letter is A-Z -> 0-25, 5 bits, so the 10-bit country field
// is simply (letter1 << 5 | letter2). Letter2's range (0-31) never
// overflows into letter1's bits, so comparing the packed 10-bit
// value as a plain integer is *exactly* equivalent to comparing
// the two letters lexicographically -- i.e. ISO alpha-2 order,
// unconditionally, forever. Unlike an index into an append-only
// table (areas.h's AREA field), a newly-recognised ISO code just
// sorts wherever its letters put it -- nothing to reshuffle, no
// table to append to.

#define PC_LETTER_BITS 5

static inline uint16_t pc_pack_country (char c1, char c2) {
   return (uint16_t) (((c1 - 'A') << PC_LETTER_BITS) | (c2 - 'A'));
}

static inline void pc_unpack_country (uint16_t country, char out[2]) {
   out[0] = (char) ('A' + (country >> PC_LETTER_BITS));
   out[1] = (char) ('A' + (country & ((1 << PC_LETTER_BITS) - 1)));
}

#endif
