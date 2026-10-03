#!/usr/bin/env python3
"""Count every addr:postcode / postal_code value in an OSM extract.
usage: extract.py file.osm.pbf out.csv CC[,CC...]
Rows: file_countries, source (addr = addr:postcode on a feature, area = postal_code on a postcode area),
      addr:country tag (if any), value, count.  ';'-separated values are split."""
import sys, csv, collections, osmium
from osmium.filter import KeyFilter
path, out, ccs = sys.argv[1], sys.argv[2], sys.argv[3]
c = collections.Counter(); objs = 0
for o in osmium.FileProcessor(path).with_filter(KeyFilter('addr:postcode', 'postal_code')):
    objs += 1
    ac = (o.tags.get('addr:country') or '').upper()[:2]
    for key, src in (('addr:postcode', 'addr'), ('postal_code', 'area')):
        v = o.tags.get(key)
        if not v: continue
        for part in v.split(';'):
            part = ' '.join(part.split())
            if part and len(part) <= 60: c[(src, ac, part)] += 1
with open(out, 'w', newline='') as f:
    w = csv.writer(f)
    for (src, ac, v), n in sorted(c.items()): w.writerow([ccs, src, ac, v, n])
print(path, objs, 'objects', len(c), 'distinct values')
