#!/usr/bin/env python3
"""The country -> postal code format table for the whole world.

Source of truth for the built-in assignments in postcode--1.3.5--2.0.0.sql
(run `python3 tools/splice.py` to regenerate the INSERTs).

Each entry: ISO 3166-1 alpha-2 -> (spec, basis)
  spec     a compiled format name (US CA FR BR CZ LU GB IE); or a pattern: a template
           ("NNNNN[-NNNN]": N digit, A letter, X either, [ ] optional) or a regular expression
           between slashes ("/[1-9]\\d{3}/"); or None for "has no postal codes"
  basis    G  matches the real GeoNames postal-code data in "@GEONAMES".world
           W  from Wikipedia's "List of postal codes" only (no GeoNames rows)
           C  a compiled format
           x  see the note

A pattern is the country's own exact set of codes, so it is as tight as the evidence supports and no
tighter: a restriction (first digit never 0, province range, fixed prefix, excluded letters) is applied
only if it rejects NO code in the GeoNames data, and is otherwise left out. See NARROWING.md.

Conventions:
  * Codes are written in their canonical form; separators (a space or hyphen the pattern has) are put
    back on input if left out.
  * A country's own letters in front of a code (VG1110, AD500, AZ 1000) are always accepted and
    dropped, so they are not part of the pattern.
  * A longer form that extends a shorter one is the optional tail ("NNNN, NNNN NNNN" -> "NNNN[ NNNN]").
  * Territories that use another country's system share its format where that is exact (GB, IE).
"""
import sys

US, CA, FR, BR, CZ, LU, GB, IE = 'US', 'CA', 'FR', 'BR', 'CZ', 'LU', 'GB', 'IE'
COMPILED = {US, CA, FR, BR, CZ, LU, GB, IE}

D = lambda lo, hi: '[%s-%s]' % (lo, hi)
ZIP4 = r'(-([1-9]\d{3}|0[1-9]\d{2}|00[1-9]\d|000[1-9]))?'      # a ZIP+4 add-on: 0000 is never one
FIRST19 = lambda n: '/[1-9]\\d{%d}/' % (n - 1)                  # n digits, the first never 0
PROV = lambda p: '/%s\\d{3}/' % p                                # a fixed first two digits
UKT = '/FIQQ 1ZZ/'                                              # (replaced per territory below)

W = {
 # ---- compiled ----
 'US': (US,'C'), 'CA': (CA,'C'), 'FR': (FR,'C'), 'BR': (BR,'C'), 'CZ': (CZ,'C'), 'LU': (LU,'C'),
 'GB': (GB,'C'), 'GG': (GB,'C'), 'IM': (GB,'C'), 'JE': (GB,'C'), 'IE': (IE,'C'), 'GI': (GB,'x'),
 # ---- US territories: the ZIPs they actually have ----
 'AS': ('/96799%s/' % ZIP4, 'G'), 'GU': ('/969\\d{2}%s/' % ZIP4, 'G'), 'PR': ('/00[6-9]\\d{2}%s/' % ZIP4, 'G'),
 'VI': ('/008\\d{2}%s/' % ZIP4, 'G'), 'MH': ('/969[67]\\d%s/' % ZIP4, 'G'), 'FM': ('/9694[1-4]%s/' % ZIP4, 'G'),
 'MP': ('/9695[0-2]%s/' % ZIP4, 'G'), 'PW': ('/96940%s/' % ZIP4, 'G'), 'UM': ('/96898%s/' % ZIP4, 'W'),
 # ---- French overseas: the French format, whose CEDEX the post offices there use too ----
 'GF': (FR,'G'), 'GP': (FR,'G'), 'MQ': (FR,'G'), 'RE': (FR,'G'), 'YT': (FR,'G'), 'NC': (FR,'G'), 'PF': (FR,'G'), 'WF': (FR,'G'),
 'PM': (FR,'G'), 'BL': (FR,'W'), 'MF': (FR,'W'),
 # ---- the British Overseas Territories: one code each ----
 'FK': ('/FIQQ 1ZZ/','G'), 'GS': ('/SIQQ 1ZZ/','G'), 'IO': ('/BBND 1ZZ/','G'), 'PN': ('/PCRN 1ZZ/','G'),
 'TC': ('/TKCA 1ZZ/','G'), 'AQ': ('/BIQQ 1ZZ/','W'), 'SH': ('/(STHL|ASCN|TDCU) 1ZZ/','W'),
 # ---- from the GeoNames data ----
 'AD': ('/[1-7]\\d{2}/','G'),  'AI': ('/2640/','G'),  'AL': ('NNNN','G'),  'AR': ('/([ABCDEFGHJKLMNPQRSTUVWXYZ]\\d{4}([A-Z]{3})?|\\d{4})/','x'),
 'AT': (FIRST19(4),'G'),  'AU': ('NNNN','G'),  'AX': ('/22\\d{3}/','G'),  'AZ': ('NNNN','G'),  'BD': (FIRST19(4),'G'),
 'BE': (FIRST19(4),'G'),  'BG': (FIRST19(4),'G'),  'BM': ('AA XX','x'),  'BY': ('NNNNNN','G'),  'CC': ('NNNN','G'),
 'CH': (FIRST19(4),'G'),  'CL': ('/[1-9]\\d{2}-\\d{4}/','G'),  'CN': ('NNNNNN','G'),  'CO': ('NNNNNN[-NNN]','G'),
 'CR': ('NNNNN[-NNNN]','G'),  'CX': ('NNNN','G'),  'CY': (FIRST19(4),'G'),
 'DE': ('/(0[1-9]|[1-9]\\d)\\d{3}/','G'),  'DK': ('NNNN','G'),  'DO': ('NNNNN','G'),  'DZ': ('NNNNN','G'),
 'EC': ('NNNNNN','G'),  'EE': (FIRST19(5),'G'),  'ES': ('/(0[1-9]|[1-4]\\d|5[0-2])\\d{3}/','G'),  'FI': ('NNNNN','G'),
 'FO': (FIRST19(3),'G'),  'GL': ('NNNN','G'),  'GT': ('NNNNN','G'),  'HK': ('NNNNNN','x'),  'HM': ('NNNN','G'),
 'HN': ('NNNNN','G'),  'HR': ('NNNNN','G'),  'HT': ('NNNN','G'),  'HU': (FIRST19(4),'G'),  'ID': ('NNNNN','G'),
 'IN': (FIRST19(6),'G'),  'IS': (FIRST19(3),'G'),  'IT': ('NNNNN','G'),  'JP': ('NNN-NNNN','G'),  'KE': ('NNNNN','G'),
 'KR': ('/(0[1-9]|[1-5]\\d|6[0-3])\\d{3}/','G'),  'LI': ('/94(8[5-9]|9[0-8])/','G'),  'LK': ('NNNNN','G'),
 'LT': ('NNNNN','G'),  'LV': ('NNNN','G'),  'MA': ('NNNNN','G'),  'MC': ('/980\\d{2}/','G'),  'MD': ('NNNN','G'),
 'MK': ('NNNN','G'),  'MO': ('NNNNNN','x'),  'MT': ('AAA[ NNNN]','x'),  'MW': ('NNNNNN','G'),
 'MX': ('/(0[1-9]|[1-9]\\d)\\d{3}/','G'),  'MY': ('/(0[1-9]|[1-9]\\d)\\d{3}/','G'),  'NF': ('NNNN','G'),
 'NL': ('/[1-9]\\d{3}( ([A-EGHJ-NPRTVWXZ][A-EGHJ-NPRSTVWXZ]|S[BCEGHJ-NPRTVWXZ]))?/','x'),
 'NO': ('NNNN','G'),  'NR': ('AAANN','G'),  'NU': ('NNNN','G'),  'NZ': ('NNNN','G'),  'PA': ('NNNN[N]','x'),
 'PE': ('NNNNN','G'),  'PH': ('NNNN','G'),  'PK': (FIRST19(5),'G'),  'PL': ('NN-NNN','G'),
 'PT': ('/[1-9]\\d{3}(-\\d{3})?/','G'),  'RO': ('NNNNNN','G'),  'RS': ('NNNNN','G'),  'RU': ('NNNNNN','G'),
 'SE': ('/[1-9]\\d{2} \\d{2}/','G'),  'SG': ('NNNNNN','G'),  'SI': (FIRST19(4),'G'),  'SJ': ('NNNN','G'),
 'SK': ('NNN NN','G'),  'SM': ('/4789\\d/','G'),  'TH': ('NNNNN','G'),  'TR': ('/(0[1-9]|[1-7]\\d|8[01]|99)\\d{3}/','G'),
 'UA': ('/(0[1-9]|[1-9]\\d)\\d{3}/','G'),  'UY': (FIRST19(5),'G'),  'VA': ('/00120/','G'),  'WS': ('NNNN','x'),
 'ZA': ('NNNN','G'),
 # ---- from Wikipedia only ----
 'AF': ('NNNN','W'),   'AM': ('NNNN','W'),   'BH': ('NNN[N]','W'), 'BB': ('NNNNN','W'),   'BT': ('NNNNN','W'),
 'BA': ('NNNNN','W'),  'VG': ('NNNN','W'),   'BN': ('/[A-Z]{2}\\d{4}/','W'),  'KH': ('NNNNN[N]','W'),
 'CV': ('NNNN','W'),   'KY': ('/[1-3]-\\d{4}/','W'),  'CU': (FIRST19(5),'W'),  'SV': ('NNNN[N]','W'),
 'EG': ('NNNNN[NN]','x'),  'SZ': ('/[HLMS]\\d{3}/','W'),  'ET': ('NNNN','W'),  'GE': ('NNNN','W'),
 'GH': ('/[A-Z][A-Z0-9]\\d{3,5}/','W'),  'GR': ('/[1-8]\\d{2} \\d{2}/','W'),  'GN': ('NNN','W'),  'GW': ('NNNN','W'),
 'IR': ('NNNNN[-NNNNN]','W'),  'IQ': ('NNNNN','W'),  'IL': ('NNNNN[NN]','x'),  'JM': ('NN','W'),  'JO': ('NNNNN','W'),
 'KZ': ('/\\d{6}|[A-Z]\\d\\d[A-Z]\\d[A-Z]\\d/','W'),  'XK': ('NNNNN','W'),  'KW': ('NNNNN','W'),  'KG': ('NNNNNN','W'),
 'LA': ('NNNNN','W'),  'LB': ('NNNN[ NNNN]','W'),  'LS': ('NNN','W'),  'LR': ('NNNN','W'),  'MG': ('NNN','W'),
 'MV': ('NNNNN','W'),  'MU': ('/[0-9A-Z]\\d{4}/','W'),  'MN': ('NNNNN','W'),  'ME': ('NNNNN','W'),
 'MS': ('/MSR \\d{4}/','W'),  'MM': ('NNNNN[NN]','x'),  'MZ': ('NNNN[-NN]','W'),  'NA': ('NNNNN','W'),
 'NP': ('NNNNN','W'),  'NI': (FIRST19(5),'W'),  'NE': ('NNNN','W'),  'NG': ('NNNNNN','W'),  'OM': ('NNN','W'),
 'PS': ('NNN','W'),  'PG': ('NNN','W'),  'PY': ('NNNN[NN]','W'),  'KN': ('NNNN','W'),  'LC': ('NN NNN','W'),
 'VC': ('NNNN','W'),  'SA': ('NNNNN[-NNNN]','W'),  'SN': ('NNNNN','W'),  'SO': ('AA NNNNN','W'),  'SD': ('NNNNN','W'),
 'TW': ('/\\d{3}(-\\d{2,3})?/','W'),  'TJ': ('NNNNNN','W'),  'TZ': ('NNNNN','W'),  'TT': ('NNNNNN','W'),
 'TN': (FIRST19(4),'W'),  'TM': ('NNNNNN','W'),  'UZ': ('NNNNNN','W'),  'VE': ('NNNN[-A]','W'),  'VN': ('NNNNN[N]','x'),
 'ZM': ('NNNNN','W'),
}
# Countries and territories with no postal code system (Wikipedia).
NONE = ('AO AG AW BS BZ BJ BO BQ BW BF BI CM CF TD KM CG CD CK CI CW DJ DM TL GQ ER FJ TF GA GM GD GY KI KP LY '
        'ML MR QA RW ST SC SL SX SB SS SR SY TG TK TO TV UG VU YE ZW BV EH').split()
for c in NONE:
    W.setdefault(c, (None, 'W'))
W['AE'] = ('NNNNN[ NNNNN]', 'x')

NOTES = {
 'AR': 'NNNN (the legacy code, and what GeoNames has), the province letter + 4 digits (B1832), or the full 8-character CPA (B1832GMR); all three are common in OpenStreetMap',
 'BM': 'AA NN; the second pair is sometimes letters, so X; Wikipedia lists AA NN and AA AA',
 'GI': 'GX11 1AA, the UK format',
 'HK': 'no postal codes; 999077 is the placeholder GeoNames carries',
 'MO': 'no postal codes; 999078 is the placeholder GeoNames carries',
 'MT': 'the outcode alone (GeoNames has these), optionally with NNNN',
 'NL': 'four digits (the first never 0), optionally with two letters (never F I O Q U Y, never SA SD SS)',
 'PA': 'Wikipedia says 4 digits, GeoNames has 5; both accepted',
 'EG': 'Wikipedia says 7 digits, the post office uses 5; both accepted',
 'MM': 'Wikipedia says 7 digits, 5 are in use; both accepted',
 'VN': 'Wikipedia says 5 digits; 6 are in use since 2004; both accepted',
 'IL': '7 digits since 2013; 5-digit codes are still widely used; both accepted',
 'AE': ('no postal code system, but two location schemes: Abu Dhabi has 5-digit area codes (20000 central Abu Dhabi, 23251 Khalifa City, '
        '20014 Yas Island), and Dubai numbers every building with a 10-digit Makani code written NNNNN NNNNN (all 178,171 GeoNames rows are '
        'Dubai). One format holds both, so any 5 digits pass. Sharjah\'s PCS is not modelled; most UAE addresses give a PO Box, which is rejected'),
 'WS': 'Wikipedia: four digits; the one GeoNames row is American Samoa\'s ZIP, filed under the wrong country',
 'CO': 'six digits, with the optional -NNN extension seen in a quarter of OpenStreetMap values (630001-025)',
 'MZ': 'four digits, with the optional -NN extension seen in OpenStreetMap values (0101-01)',
 'IR': 'the 10-digit code, whose first five digits are a locality block; OpenStreetMap\'s mapped postcode areas use those five alone, so the second half is optional',
 'CR': 'five digits; Wikipedia also lists a NNNNN-NNNN street-level extension, taken as the optional tail',
 'DE': 'five digits, never starting 00; Wikipedia also lists the 2- and 4-digit regional leading digits (Leitregion), which are prefixes, not codes: search them with the % operator',
 'TW': 'three digits with an optional 2 or 3 digit extension (100, 100-12, 100-123)',
 'GH': 'a letter, a letter or digit, then 3 to 5 digits (Wikipedia: A?NNN, A?NNNN, A?NNNNN)',
 'KZ': 'six digits, or the newer alphanumeric form A05B1H4',
 'TR': 'province 01 to 81, and 99 (the Turkish-controlled north of Cyprus)',
 'ES': 'province 01 to 52',
 'KR': 'area 01 to 63',
 'HN': 'five digits (GeoNames); Wikipedia also lists an older AANNNN form, not accepted',
 'PE': 'five digits; Wikipedia also lists a CC NNNN form, not accepted',
 'SG': 'six digits; Wikipedia also lists the old 2- and 4-digit forms, not accepted; Singapore also uses non-sequential sectors (88, 91), so it is not tightened',
 'UM': 'US ZIP (96898)',
 'PR': 'US ZIPs 006xx to 009xx', 'VI': 'US ZIPs 008xx', 'GU': 'US ZIPs 969xx', 'MH': 'US ZIPs 96960 to 96979 (969 6x/7x)',
 'FM': 'US ZIPs 96941 to 96944', 'MP': 'US ZIPs 96950 to 96952', 'PW': 'US ZIP 96940', 'AS': 'US ZIP 96799',
 'GF': 'the French format: the overseas departments use CEDEX too, which a 97xxx/98xxx pattern would refuse (GeoNames has "97305 CEDEX")',
 'GP': 'the French format (CEDEX)', 'MQ': 'the French format (CEDEX)', 'RE': 'the French format (CEDEX)', 'YT': 'the French format (CEDEX)',
 'NC': 'the French format', 'PF': 'the French format', 'WF': 'the French format', 'PM': 'the French format', 'BL': 'the French format', 'MF': 'the French format',
 'AQ': 'a single code, BIQQ 1ZZ', 'FK': 'a single code, FIQQ 1ZZ', 'GS': 'a single code, SIQQ 1ZZ', 'IO': 'a single code, BBND 1ZZ',
 'PN': 'a single code, PCRN 1ZZ', 'TC': 'a single code, TKCA 1ZZ', 'SH': 'three codes: STHL, ASCN and TDCU, each 1ZZ',
 'AI': 'a single code, 2640 (written AI-2640)', 'VA': 'a single code, 00120', 'SM': '4789x', 'MC': '980xx', 'LI': '9485 to 9498',
 'AX': '22xxx', 'AD': '100 to 799 (written AD500)', 'MS': 'MSR followed by four digits',
}
BASIS = {'C': 'built in', 'G': 'GeoNames data', 'W': 'Wikipedia', 'x': 'see note'}
EXTRA_NAMES = {'BV': 'Bouvet Island', 'EH': 'Western Sahara'}


def sql_text(names):
    q = lambda x: "'" + x.replace("'", "''") + "'"
    out = ["-- BEGIN generated by tools/world_formats.py -- edit that, not this",
           "-- Each country with a pattern gets its own language, version 1; the stored pattern is worked out by the",
           "-- extension itself (postal_code_pattern_check), from the spec given here."]
    langs = [(c, W[c][0]) for c in sorted(W) if W[c][0] and W[c][0] not in COMPILED]
    out.append("INSERT INTO postal_code_languages (iso2, version, source, pattern, builtin)\n"
               "   SELECT iso2, 1, spec, postal_code_pattern_check(spec), true FROM (VALUES")
    out.append(",\n".join("   (%s, %s)" % (q(c), q(s)) for c, s in langs))
    out.append(") v(iso2, spec);")
    rows = []
    for c in sorted(W):
        f, b = W[c]
        if f is None or b == 'C': continue
        rows.append("   (%s, %s)" % (q(c), q(f if f in COMPILED else 'pattern')))
    out.append("INSERT INTO postal_code_builtin_countries (iso2, format_name) VALUES\n" + ",\n".join(rows) + ";")
    out.append("INSERT INTO postal_code_iso_countries (iso2, name, basis, note) VALUES")
    rows = []
    for c in sorted(W):
        f, b = W[c]
        rows.append("   (%s, %s, %s, %s)" % (q(c), q(names[c]), q(BASIS[b] if f else 'no postal codes'), q(NOTES[c]) if c in NOTES else 'NULL'))
    out.append(",\n".join(rows) + ";")
    out.append("-- END generated")
    return "\n".join(out) + "\n"


if __name__ == '__main__':
    if '--sql' in sys.argv:
        names = dict(EXTRA_NAMES)
        for l in open(sys.argv[sys.argv.index('--sql') + 1]):
            c, n = l.split('\t')[:2]
            names[c] = n
        sys.stdout.write(sql_text(names))
    else:
        for c in sorted(W): print(c, *W[c])
        print(len(W), 'countries,', sum(1 for f, b in W.values() if f), 'with a format', file=sys.stderr)
