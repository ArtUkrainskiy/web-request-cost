#!/usr/bin/env python3
# CPU per request of each driver setting: median and min-max of the passes.
#   python3 summary.py data/*.jsonl
import json, statistics as st, sys


def m(r):
    """As in ../2026-10/aggregate.py: cgroup CPU between the snapshots around wrk / requests completed."""
    w, cw = r['wrk'], r['cpu_window']
    n = w['requests']
    dbg = 'blog-pg' if r['db'] == 'pgsql' else 'blog-mysql'
    return {'scpu': cw['stack'] / n * 1000, 'dbcpu': cw[dbg] / n * 1000, 'p99': w['p99_us'] / 1000,
            'rps': n / (w['duration_us'] / 1e6)}


rows = {}
for p in sys.argv[1:]:
    for line in open(p):
        r = json.loads(line)
        env = r.get('env', '').strip()
        key = (r['stack'], r['db'], env.split('=', 1)[1] if env.startswith('DSN_SUFFIX=') else 'default')
        rows.setdefault(key, []).append(m(r))

def f(v):
    return f'{st.median(v):.3f} [{min(v):.3f}–{max(v):.3f}]'

print('| stack | db | DSN suffix | passes | stack CPU, ms | DB CPU, ms | stack + DB, ms | p99, ms |')
print('|---|---|---|---:|---:|---:|---:|---:|')
for (s, d, v), runs in sorted(rows.items()):
    tot = [x['scpu'] + x['dbcpu'] for x in runs]
    print(f"| {s} | {d} | `{v}` | {len(runs)} | {f([x['scpu'] for x in runs])} | {f([x['dbcpu'] for x in runs])} | {f(tot)} | {st.median(x['p99'] for x in runs):.1f} |")
