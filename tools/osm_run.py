#!/usr/bin/env python3
"""Download each Geofabrik country extract, count its postcodes, delete the extract. Resumable."""
import json, os, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor
sel = json.load(open('/osm/selected.json'))
os.makedirs('/osm/pbf', exist_ok=True); os.makedirs('/osm/out', exist_ok=True)
def log(m):
    with open('/osm/progress.log', 'a') as f: f.write(time.strftime('%H:%M:%S ') + m + '\n')
def work(item):
    id_, iso, url = item
    out = f'/osm/out/{id_}.csv'
    if os.path.exists(out): return
    pbf = f'/osm/pbf/{id_}.osm.pbf'
    t0 = time.time()
    for attempt in range(4):
        r = subprocess.run(['curl', '-sL', '-C', '-', '--retry', '3', '-o', pbf, '-w', '%{http_code}', url],
                           capture_output=True, text=True)
        if r.stdout.strip() in ('200', '206', '416') and os.path.getsize(pbf) > 1000: break
        log(f'{id_}: download attempt {attempt+1} gave {r.stdout.strip()}'); time.sleep(20)
    else:
        log(f'{id_}: DOWNLOAD FAILED'); return
    size = os.path.getsize(pbf) / 1e6
    t1 = time.time()
    p = subprocess.run(['nice', '-n', '19', '/root/osmenv/bin/python', '/osm/extract.py', pbf, out + '.tmp', ','.join(iso)],
                       capture_output=True, text=True)
    if p.returncode != 0:
        log(f'{id_}: EXTRACT FAILED {p.stderr[-300:]}'); return
    os.rename(out + '.tmp', out); os.remove(pbf)
    log(f'{id_}: ok {size:.0f} MB, download {t1-t0:.0f}s, extract {time.time()-t1:.0f}s :: {p.stdout.strip().split(chr(10))[-1]}')
with ThreadPoolExecutor(4) as ex: list(ex.map(work, sel))
log('ALL DONE')
