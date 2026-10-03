#!/usr/bin/env python3
"""The country -> postal code format table for the whole world.

Source of truth for the built-in assignments in postcode--1.3.5--2.0.0.sql
(run `python3 tools/world_formats.py --sql` to regenerate the INSERTs).

Each entry: ISO 3166-1 alpha-2 -> (format, basis)
  format   a compiled format name (US CA FR BR CZ LU GB IE), or a template
           (see postal_code_template.h), or None for "has no postal codes"
  basis    G  matches the real GeoNames postal-code data in "@GEONAMES".world
           W  from Wikipedia's "List of postal codes" only (no GeoNames rows)
           C  a compiled format that existed already
           x  see the note

Rules used:
  * Separators are optional on input and written canonically, so a written
    alternative that differs only by separator ("NNNNNNN" / "NNN-NNNN") is one
    template.
  * A longer alternative that extends a shorter one is the optional tail
    ("NNNN, NNNN NNNN" -> "NNNN[ NNNN]").
  * A "CC-" prefix written with a hyphen is the UPU country prefix, which the
    type already strips, so it is not part of the template (LV, MD, LT, ...).
    Where the domestic form carries the country's own letters without a hyphen
    (AD500, AZ 1000, VG1110, HT6110) the template begins CC: those letters are
    optional on input, checked against the country, never stored, and not
    written back, so VG1110, VG-1110 and VG-VG1110 are one value, VG-1110.
  * Territories that use another country's system share its format.
  * Where Wikipedia is doubtful (Egypt, Myanmar, Vietnam, Israel) the template
    accepts both lengths: "NNNNN[NN]".
  * A template cannot fix digits ("973NN" for French Guiana), so such
    territories use their parent's format and accept slightly more than is
    really in use.
"""
import sys

US, CA, FR, BR, CZ, LU, GB, IE = 'US', 'CA', 'FR', 'BR', 'CZ', 'LU', 'GB', 'IE'
UKT = 'AAAA NAA'            # the British Overseas Territories' single codes (FIQQ 1ZZ, ...)

W = {
 # ---- shipped before templates existed (compiled) ----
 'US': (US,'C'), 'CA': (CA,'C'), 'FR': (FR,'C'), 'BR': (BR,'C'), 'CZ': (CZ,'C'), 'LU': (LU,'C'),
 'GB': (GB,'C'), 'GG': (GB,'C'), 'IM': (GB,'C'), 'JE': (GB,'C'), 'IE': (IE,'C'),
 # ---- sharing another country's system ----
 'AS': (US,'G'), 'GU': (US,'G'), 'MH': (US,'G'), 'FM': (US,'G'), 'MP': (US,'G'), 'PW': (US,'G'),
 'PR': (US,'G'), 'VI': (US,'G'), 'UM': (US,'W'),
 'GF': (FR,'G'), 'GP': (FR,'G'), 'MQ': (FR,'G'), 'RE': (FR,'G'), 'YT': (FR,'G'), 'PM': (FR,'G'),
 'NC': (FR,'G'), 'PF': (FR,'G'), 'WF': (FR,'G'), 'BL': (FR,'W'), 'MF': (FR,'W'),
 'GI': (GB,'x'),
 # ---- from the GeoNames data ----
 'AD': ('CCNNN','G'),  'AI': ('NNNN','G'),   'AL': ('NNNN','G'),   'AR': ('[A]NNNN[AAA]','x'),  'AT': ('NNNN','G'),
 'AU': ('NNNN','G'),   'AX': ('NNNNN','G'),  'AZ': ('CC NNNN','G'), 'BD': ('NNNN','G'),  'BE': ('NNNN','G'),
 'BG': ('NNNN','G'),   'BM': ('AA XX','x'),  'BY': ('NNNNNN','G'), 'CC': ('NNNN','G'),   'CH': ('NNNN','G'),
 'CL': ('NNN-NNNN','G'), 'CN': ('NNNNNN','G'), 'CO': ('NNNNNN[-NNN]','G'), 'CR': ('NNNNN[-NNNN]','G'),  'CX': ('NNNN','G'),
 'CY': ('NNNN','G'),   'DE': ('NNNNN','G'),  'DK': ('NNNN','G'),   'DO': ('NNNNN','G'),   'DZ': ('NNNNN','G'),
 'EC': ('NNNNNN','G'), 'EE': ('NNNNN','G'),  'ES': ('NNNNN','G'),  'FI': ('NNNNN','G'),   'FK': (UKT,'G'),
 'FO': ('NNN','G'),    'GL': ('NNNN','G'),   'GS': (UKT,'G'),     'GT': ('NNNNN','G'),    'HK': ('NNNNNN','x'),
 'HM': ('NNNN','G'),   'HN': ('NNNNN','G'),  'HR': ('NNNNN','G'), 'HT': ('CCNNNN','G'),   'HU': ('NNNN','G'),
 'ID': ('NNNNN','G'),  'IN': ('NNNNNN','G'), 'IO': (UKT,'G'),     'IS': ('NNN','G'),      'IT': ('NNNNN','G'),
 'JP': ('NNN-NNNN','G'), 'KE': ('NNNNN','G'), 'KR': ('NNNNN','G'), 'LI': ('NNNN','G'),     'LK': ('NNNNN','G'),
 'LT': ('NNNNN','G'),  'LV': ('NNNN','G'),   'MA': ('NNNNN','G'),  'MC': ('NNNNN','G'),    'MD': ('NNNN','G'),
 'MK': ('NNNN','G'),   'MO': ('NNNNNN','x'), 'MT': ('AAA[ NNNN]','x'), 'MW': ('NNNNNN','G'), 'MX': ('NNNNN','G'),
 'MY': ('NNNNN','G'),  'NF': ('NNNN','G'),   'NL': ('NNNN[ AA]','x'), 'NO': ('NNNN','G'),    'NR': ('AAANN','G'),
 'NU': ('NNNN','G'),   'NZ': ('NNNN','G'),   'PA': ('NNNN[N]','x'),  'PE': ('NNNNN','G'),     'PH': ('NNNN','G'),
 'PK': ('NNNNN','G'),  'PL': ('NN-NNN','G'), 'PN': (UKT,'G'),      'PT': ('NNNN[-NNN]','G'),'RO': ('NNNNNN','G'),
 'RS': ('NNNNN','G'),  'RU': ('NNNNNN','G'), 'SE': ('NNN NN','G'), 'SG': ('NNNNNN','G'),    'SI': ('NNNN','G'),
 'SJ': ('NNNN','G'),   'SK': ('NNN NN','G'), 'SM': ('NNNNN','G'),  'TC': (UKT,'G'),         'TH': ('NNNNN','G'),
 'TR': ('NNNNN','G'),  'UA': ('NNNNN','G'),  'UY': ('NNNNN','G'),  'VA': ('NNNNN','G'),     'WS': ('CCNNNN','x'),
 'ZA': ('NNNN','G'),
 # ---- from Wikipedia only ----
 'AF': ('NNNN','W'),   'AM': ('NNNN','W'),   'BH': ('NNN[N]','W'), 'BB': ('CCNNNNN','W'),   'BT': ('NNNNN','W'),
 'BA': ('NNNNN','W'),  'AQ': (UKT,'W'),      'VG': ('CCNNNN','W'), 'BN': ('AANNNN','W'),    'KH': ('NNNNNN','W'),
 'CV': ('NNNN','W'),   'KY': ('CCN-NNNN','W'), 'CU': ('NNNNN','W'), 'SV': ('NNNN','W'),      'EG': ('NNNNN[NN]','x'),
 'SZ': ('ANNN','W'),   'ET': ('NNNN','W'),   'GE': ('NNNN','W'),   'GH': ('AXNNN[NN]','W'),  'GR': ('NNN NN','W'),
 'GN': ('NNN','W'),    'GW': ('NNNN','W'),   'IR': ('NNNNN-NNNNN','W'), 'IQ': ('NNNNN','W'),  'IL': ('NNNNN[NN]','x'),
 'JM': ('NN','W'),     'JO': ('NNNNN','W'),  'KZ': ('NNNNNN','W'), 'XK': ('NNNNN','W'),      'KW': ('NNNNN','W'),
 'KG': ('NNNNNN','W'), 'LA': ('NNNNN','W'),  'LB': ('NNNN[ NNNN]','W'), 'LS': ('NNN','W'),    'LR': ('NNNN','W'),
 'MG': ('NNN','W'),    'MV': ('NNNNN','W'),  'MU': ('XNNNN','W'),  'MN': ('NNNNN','W'),       'ME': ('NNNNN','W'),
 'MS': ('AAA NNNN','W'), 'MM': ('NNNNN[NN]','x'), 'MZ': ('NNNN[-NN]','W'), 'NA': ('NNNNN','W'),     'NP': ('NNNNN','W'),
 'NI': ('NNNNN','W'),  'NE': ('NNNN','W'),   'NG': ('NNNNNN','W'), 'OM': ('NNN','W'),         'PS': ('NNN','W'),
 'PG': ('NNN','W'),    'PY': ('NNNN[NN]','W'), 'KN': ('CCNNNN','W'), 'LC': ('CCNN NNN','W'),  'VC': ('CCNNNN','W'),
 'SA': ('NNNNN[-NNNN]','W'), 'SN': ('NNNNN','W'), 'SH': (UKT,'W'),  'SO': ('AA NNNNN','W'),   'SD': ('NNNNN','W'),
 'TW': ('NNN[-NNN]','W'), 'TJ': ('NNNNNN','W'), 'TZ': ('NNNNN','W'), 'TT': ('NNNNNN','W'),     'TN': ('NNNN','W'),
 'TM': ('NNNNNN','W'), 'UZ': ('NNNNNN','W'), 'VE': ('NNNN[-A]','W'), 'VN': ('NNNNN[N]','x'),   'ZM': ('NNNNN','W'),
 'MR': (None,'W'),
}
# Countries and territories with no postal code system (Wikipedia).
NONE = ('AO AG AW BS BZ BJ BO BQ BW BF BI CM CF TD KM CG CD CK CI CW DJ DM TL GQ ER FJ TF GA GM GD GY KI KP LY '
        'ML NR_ QA RW ST SC SL SX SB SS SR SY TG TK TO TV UG VU YE ZW BV EH').replace('NR_', '').split()
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
 'NL': 'NNNN, optionally with the two letters; GeoNames has the four digits only',
 'PA': 'Wikipedia says 4 digits, GeoNames has 5; both accepted',
 'CR': 'five digits; Wikipedia also lists a NNNNN-NNNN street-level extension, taken as the optional tail',
 'EG': 'Wikipedia says 7 digits, the post office uses 5; both accepted',
 'MM': 'Wikipedia says 7 digits, 5 are in use; both accepted',
 'VN': 'Wikipedia says 5 digits; 6 are in use since 2004; both accepted',
 'IL': '7 digits since 2013; 5-digit codes are still widely used; both accepted',
 'AE': 'no postal code system, but two location schemes: Abu Dhabi has 5-digit area codes (20000 central Abu Dhabi, 23251 Khalifa City, 20014 Yas Island), and Dubai numbers every building with a 10-digit Makani code written NNNNN NNNNN (all 178,171 GeoNames rows are Dubai). One format holds both, so any 5 digits pass. Sharjah\'s PCS is not modelled; most UAE addresses give a PO Box, which is rejected',
 'UM': 'US ZIP (96898)',
 'CO': 'six digits, with the optional -NNN extension seen in a quarter of OpenStreetMap values (630001-025)',
 'MZ': 'four digits, with the optional -NN extension seen in OpenStreetMap values (0101-01)',
 'MU': 'Wikipedia lists NNNNN and RNNNN (Rodrigues); the first character may be any letter or digit',
 'WF': '986NN; the French format accepts any five digits',
 'PF': '987NN; the French format accepts any five digits',
 'NC': '988NN; the French format accepts any five digits',
 'MF': '97150; the French format accepts any five digits',
 'BL': '97133; the French format accepts any five digits',
 'PM': '97500; the French format accepts any five digits',
 'YT': '976NN; the French format accepts any five digits',
 'RE': '974NN; the French format accepts any five digits',
 'MQ': '972NN; the French format accepts any five digits',
 'GP': '971NN; the French format accepts any five digits',
 'GF': '973NN; the French format accepts any five digits',
 'MS': 'MSR NNNN; the format accepts any three letters',
 'MC': '980NN; the format accepts any five digits',
 'SM': '4789N; the format accepts any five digits',
 'VA': 'a single code (00120); the format accepts any five digits',
 'AI': 'a single code (AI-2640, written with the country hyphen); the format accepts any four digits',
 'TC': 'a single code (TKCA 1ZZ); the format accepts any code of that shape',
 'SH': 'a single code (STHL 1ZZ); the format accepts any code of that shape',
 'PN': 'a single code (PCRN 1ZZ); the format accepts any code of that shape',
 'IO': 'a single code (BBND 1ZZ); the format accepts any code of that shape',
 'GS': 'a single code (SIQQ 1ZZ); the format accepts any code of that shape',
 'FK': 'a single code (FIQQ 1ZZ); the format accepts any code of that shape',
 'AQ': 'a single code (BIQQ 1ZZ); the format accepts any code of that shape',
 'TW': 'NNN with an optional -NNN; the older 5-digit NNN-NN is not accepted',
 'SG': 'six digits; Wikipedia also lists the old 2- and 4-digit forms, not accepted',
 'PE': 'five digits; Wikipedia also lists a CC NNNN form, not accepted',
 'HN': 'five digits (GeoNames); Wikipedia also lists an older AANNNN form, not accepted',
 'GH': 'Wikipedia lists A?NNN, A?NNNN and A?NNNNN (5, 6 and 7 characters); a template can hold only two lengths, so 5 and 7 are accepted',
 'DE': 'five digits; Wikipedia also lists the 2- and 4-digit regional leading digits (Leitregion), which are prefixes, not codes: search them with the % operator',
 'WS': 'Wikipedia: CCNNNN; the one GeoNames row is American Samoa\'s ZIP, filed under the wrong country',
}
BASIS = {'C': 'built in', 'G': 'GeoNames data', 'W': 'Wikipedia', 'x': 'see note'}
EXTRA_NAMES = {'BV': 'Bouvet Island', 'EH': 'Western Sahara'}

# Template slots are permanent, so they are never derived from sorting: this is the order they were
# shipped in. A new template is APPENDED here (the generator refuses a template that is missing, so
# adding a country with a new shape forces this edit).
SLOT_ORDER = ['AA NNNNN', 'AA XX', 'AAA NNNN', 'AAAA NAA', 'AAANN', 'AAA[ NNNN]', 'AANNNN', 'ANNN', 'AXNNN[NN]', 'CC NNNN', 'CCN-NNNN', 'CCNN NNN', 'CCNNN', 'CCNNNN', 'CCNNNNN', 'NN', 'NN-NNN', 'NNN', 'NNN NN', 'NNN-NNNN', 'NNNN', 'NNNNN', 'NNNNN-NNNNN', 'NNNNNN', 'NNNNN[-NNNN]', 'NNNNN[NN]', 'NNNNN[N]', 'NNNN[ AA]', 'NNNN[ NNNN]', 'NNNN[-A]', 'NNNN[-NNN]', 'NNNN[NN]', 'NNN[-NNN]', 'NNN[N]', 'XNNNN', 'NNNNN[ NNNNN]', 'NNNN[N]', 'NNNNNN[-NNN]', 'NNNN[-NN]', '[A]NNNN[AAA]']

def sql_text(names):
    compiled = set('US CA FR BR CZ LU GB IE'.split())
    tpls = list(SLOT_ORDER)
    used = {f for f, b in W.values() if f and f not in compiled}
    assert used <= set(tpls), 'new template(s) not in SLOT_ORDER (append them): %s' % sorted(used - set(tpls))
    assert len(set(tpls)) == len(tpls) and len(tpls) <= 51
    q = lambda x: "'" + x.replace("'", "''") + "'"
    out = ["-- BEGIN generated by tools/world_formats.py -- edit that, not this",
           "-- Template slots are permanent: this list only ever grows (append, never reorder).",
           "INSERT INTO postal_code_templates (slot, template, builtin) VALUES"]
    out.append(",\n".join(f"   ({12 + i}, {q(t)}, true)" for i, t in enumerate(tpls)) + ";")
    out.append("INSERT INTO postal_code_formats (name, description)\n   SELECT 'template:' || template, 'Template ' || template FROM postal_code_templates WHERE builtin;")
    out.append("UPDATE postal_code_formats SET builtin = true;          -- everything present at install is shipped")
    rows = []
    for c in sorted(W):
        f, b = W[c]
        if f is None or b == 'C': continue
        rows.append(f"   ({q(c)}, {q(f if f in compiled else 'template:' + f)})")
    out.append("INSERT INTO postal_code_builtin_countries (iso2, format_name) VALUES\n" + ",\n".join(rows) + ";")
    out.append("INSERT INTO postal_code_iso_countries (iso2, name, basis, note) VALUES")
    rows = []
    for c in sorted(W):
        f, b = W[c]
        rows.append(f"   ({q(c)}, {q(names[c])}, {q(BASIS[b] if f else 'no postal codes' if b != 'x' else 'no postal codes')}, {q(NOTES[c]) if c in NOTES else 'NULL'})")
    out.append(",\n".join(rows) + ";")
    out.append("-- END generated")
    return "\n".join(out) + "\n"

if __name__ == '__main__':
    compiled = set('US CA FR BR CZ LU GB IE'.split())
    tpls = sorted({f for f, b in W.values() if f and f not in compiled})
    if '--sql' in sys.argv:
        names = dict(EXTRA_NAMES)
        for l in open(sys.argv[sys.argv.index('--sql') + 1]):
            c, n = l.split('\t')[:2]
            names[c] = n
        sys.stdout.write(sql_text(names))
    else:
        for c in sorted(W): print(c, *W[c])
        print(len(W), 'countries,', len(tpls), 'templates', file=sys.stderr)
