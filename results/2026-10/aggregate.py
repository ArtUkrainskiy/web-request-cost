#!/usr/bin/env python3
# Builds tables.md from data/raw/*.jsonl and prices.json. Every published number comes from here.
#   python3 aggregate.py > tables.md
import glob, json, os, statistics as st

HERE = os.path.dirname(os.path.abspath(__file__))
GROUPS = [
    ('PHP', [('fpm', 'PHP FPM + nginx'), ('franken', 'PHP FrankenPHP worker'), ('rr', 'PHP RoadRunner'), ('swoole', 'PHP Swoole')]),
    ('Go', [('go', 'Go net/http')]),
    ('Node', [('node-http', 'Node node:http'), ('node-fastify', 'Node Fastify')]),
    ('Other', [('rust', 'Rust hyper'), ('java', 'Java Jetty 12, virtual threads'), ('dotnet', '.NET 10 Kestrel'),
               ('python', 'Python uvicorn'), ('ruby', 'Ruby Puma')]),
]
NAMES = {s: n for _, g in GROUPS for s, n in g}
ORDER = [s for _, g in GROUPS for s, _ in g]
MB = 2 ** 20


def load(prefix):
    """Rows of the files data/raw/<prefix>*.jsonl and the names of those files."""
    paths = sorted(glob.glob(os.path.join(HERE, 'data/raw', prefix + '*.jsonl')))
    return [os.path.basename(p) for p in paths], [json.loads(l) for p in paths for l in open(p)]


def m(r):
    """Per-run metrics. CPU per request is the cgroup CPU time between the snapshots taken right before
    and right after wrk (`cpu_window`) divided by the requests wrk completed."""
    w, s, cw = r['wrk'], r['sample'], r['cpu_window']
    n = w['requests']
    rps = n / (w['duration_us'] / 1e6)
    dbg = 'blog-pg' if r['db'] == 'pgsql' else 'blog-mysql'
    ms = s['stack']['mem_stat_at_max']
    return {
        'rps': rps, 'p50': w['p50_us'] / 1000, 'p99': w['p99_us'] / 1000,
        'mem': (ms['anon'] + ms.get('shmem', 0) + ms.get('kernel', 0)) / MB, 'anon': ms['anon'] / MB,
        'scpu': cw['stack'] / n * 1000, 'dbcpu': cw[dbg] / n * 1000,
        'cores': cw['stack'] / cw['seconds'], 'dbcores': cw[dbg] / cw['seconds'],
    }


def agg(runs, key):
    vals = [x[key] for x in runs]
    return st.median(vals), min(vals), max(vals)


def fmt(v, f, spread=False):
    med, lo, hi = v
    if not spread or lo == hi:
        return f'{med:{f}}'
    return f'{med:{f}} [{lo:{f}}–{hi:{f}}]'


out = []
p = out.append

# ---------------------------------------------------------------- memory series
files, rows = load('memory-')
M = {}
for r in rows:
    M.setdefault((r['stack'], r['db'], r['c']), []).append(m(r))
passes = max(len(v) for v in M.values()) if M else 0
p(f'## 1. Memory and CPU at equal numbers of clients: stack on 4 cores (8 threads), C = 1/10/50/200, {passes} passes\n')
p(f'Files: {", ".join("`data/raw/" + f + "`" for f in files)}. Median of the passes, [min–max] in brackets. Memory: anon + shmem + kernel of all the stack\'s containers at the peak of `memory.current` (anon separately). CPU: cgroup CPU seconds between snapshots right before and after wrk, per completed request.\n')
for db in ('pgsql', 'mysql'):
    p(f'\n### {db}\n')
    p('| stack | memory, MB at C=1 / 10 / 50 / 200 | anon at C=50, MB | req/s at C=200 | p50 / p99 at C=200, ms | stack CPU at C=50, ms/request | DB CPU at C=50, ms/request | stack / DB cores at C=200 |')
    p('|---|---|---:|---:|---:|---:|---:|---:|')
    for s in ORDER:
        if (s, db, 200) not in M:
            p(f'| {NAMES[s]} | no data | | | | | | |')
            continue
        mem = ' / '.join(fmt(agg(M[(s, db, c)], 'mem'), '.0f') if (s, db, c) in M else '—' for c in (1, 10, 50, 200))
        a, b = M[(s, db, 200)], M.get((s, db, 50), M[(s, db, 200)])
        p(f"| {NAMES[s]} | {mem} | {fmt(agg(b, 'anon'), '.0f')} | {fmt(agg(a, 'rps'), '.0f', True)} | "
          f"{fmt(agg(a, 'p50'), '.1f')} / {fmt(agg(a, 'p99'), '.1f')} | {fmt(agg(b, 'scpu'), '.3f', True)} | "
          f"{fmt(agg(b, 'dbcpu'), '.3f')} | {fmt(agg(a, 'cores'), '.2f')} / {fmt(agg(a, 'dbcores'), '.2f')} |")

# ---------------------------------------------------------------- waiting series
f100, r100 = load('wait100-')
f1000, r1000 = load('wait1000-')
wfiles, wrows = f100 + f1000, r100 + r1000
W = {}
for r in wrows:
    W.setdefault((r['stack'], int(r['upstream'].split('ms=')[1]), r['c']), []).append(m(r))


def wmed(k):
    """Median of every metric over the passes of one waiting run."""
    return {key: st.median(x[key] for x in W[k]) for key in W[k][0]}


WPASSES = max(len(v) for v in W.values())
p(f'\n## 2. Waiting: PostgreSQL, stack on 4 cores, every request waits on an external service\n')
p(f'Files: {", ".join("`data/raw/" + f + "`" for f in wfiles)}. Provisioned for the load: blocking models get a worker per client (FPM, FrankenPHP, RoadRunner; RoadRunner accepts at most 500 workers) or 2 × ⌈C/N⌉ threads per Puma worker (Ruby); the PHP blocking models reach PostgreSQL through PgBouncer. Event-loop and virtual-thread stacks keep their usual configuration. Warm-up 30 s (40 s with 500+ clients), pause wait + 1 s, measured 30 s (0.1 s) and 60 s (1 s). Median of {WPASSES} passes; stack CPU with [min–max].\n')
for wait in (100, 1000):
    p(f'\n### {wait} ms wait\n')
    p('| stack | clients | req/s | p50 / p99, ms | stack cores of 8 | stack CPU, ms/request | DB CPU, ms/request | memory, MB |')
    p('|---|---:|---:|---:|---:|---:|---:|---:|')
    for s in ORDER:
        for c in (100, 500, 1000, 5000):
            if (s, wait, c) in W:
                x = wmed((s, wait, c))
                p(f"| {NAMES[s]} | {c} | {x['rps']:.0f} | {x['p50']:.0f} / {x['p99']:.0f} | {x['cores']:.2f} | {fmt(agg(W[(s, wait, c)], 'scpu'), '.2f', True)} | {x['dbcpu']:.2f} | {x['mem']:.0f} |")

# ---------------------------------------------------------------- derived units
p('\n## 3. Derived values (from section 2)\n')
p('CPU per request: "0.1 s" — the 100 ms × 100 clients run (~1000 req/s with a 0.1 s wait); "1 s" — the 1 s run with the largest number of clients up to 1000 (RoadRunner: 500). Memory per 1000 waits — memory growth at 1 s wait from 100 clients to the largest number up to 1000, and from 1000 to 5000. Base — memory at 100 clients minus 0.1 × growth.\n')
p('| stack | stack CPU 0.1 s / 1 s, ms | DB CPU 0.1 s / 1 s, ms | base, MB | MB per 1000 waits (up to 1000) | MB per 1000 waits (1000→5000) |')
p('|---|---:|---:|---:|---:|---:|')
units = {}
for s in ORDER:
    if (s, 100, 100) not in W or (s, 1000, 100) not in W:
        continue
    hi = max(c for (s_, w, c) in W if s_ == s and w == 1000 and c <= 1000)
    x01, x1 = wmed((s, 100, 100)), wmed((s, 1000, hi))
    m100 = wmed((s, 1000, 100))['mem']
    s1 = (x1['mem'] - m100) / ((hi - 100) / 1000) if hi > 100 else m100 / 0.1
    s2 = (wmed((s, 1000, 5000))['mem'] - wmed((s, 1000, 1000))['mem']) / 4 if (s, 1000, 5000) in W and (s, 1000, 1000) in W else s1
    base = max(m100 - 0.1 * s1, 0)
    units[s] = {'cpu01': x01['scpu'], 'cpu1': x1['scpu'], 'db01': x01['dbcpu'], 'db1': x1['dbcpu'], 'base': base, 's1': s1, 's2': s2}
    p(f"| {NAMES[s]} | {x01['scpu']:.2f} / {x1['scpu']:.2f}{' (' + str(hi) + ')' if hi != 1000 else ''} | {x01['dbcpu']:.2f} / {x1['dbcpu']:.2f} | {base:.0f} | {s1:.0f} | {s2:.0f}{'' if (s, 1000, 5000) in W else ' (= up to 1000)'} |")

# ---------------------------------------------------------------- cost model
prices = json.load(open(os.path.join(HERE, 'prices.json')))
pts = [(i['gib'], i['usd_per_hour']) for i in prices['aws']['instances']]
mx = sum(x for x, _ in pts) / len(pts)
my = sum(y for _, y in pts) / len(pts)
gb_h = sum((x - mx) * (y - my) for x, y in pts) / sum((x - mx) ** 2 for x, _ in pts)
vcpu_h = (my - gb_h * mx) / prices['aws']['instances'][0]['vcpu']
H = prices['aws']['hours_per_month']
ccx = next(pl for pl in prices['hetzner']['plans'] if pl['name'] == 'CCX33')
eur_vcpu = ccx['eur_new'] / ccx['vcpu']
UTIL = 7.5 / 8


def mem_mb(s, rps, wait, vcpu):
    u = units[s]
    conc = rps * (wait + 0.01)
    return u['base'] * vcpu / 8 + u['s1'] * min(conc, 1000) / 1000 + u['s2'] * max(conc - 1000, 0) / 1000


def nowait(s):
    runs = M.get((s, 'pgsql', 50))
    return (st.median(x['scpu'] for x in runs), st.median(x['dbcpu'] for x in runs), st.median(x['mem'] for x in runs)) if runs else None


def cost(v, gb):
    return (v * vcpu_h + gb * gb_h) * H, max(v, gb / 4) * eur_vcpu


p('\n## 4. Modelled cost of 1000 req/s per month, PostgreSQL\n')
p(f"Prices (`prices.json`, {prices['retrieved']}): AWS — c7i/m7i/r7i.xlarge on-demand prices decomposed into a vCPU price (${vcpu_h * H:.2f}/month) and a GB price (${gb_h * H:.2f}/month); Hetzner — €{eur_vcpu:.2f} per vCPU with 4 GB at the CCX33 price after 15 June 2026 (a price at scale, with fractional vCPUs; the smallest server, CCX13, costs €42.99). vCPU = CPU per request / {UTIL:.2f} (7.5 of 8 threads busy; at a 60% target utilisation multiply by 1.56). \"Stack\" — the application only (with nginx and PgBouncer where present); \"stack + DB\" — plus PostgreSQL's CPU at the same vCPU price. No waiting — section 1 (C=50, the CPU column shown there); with waiting — section 3; 10 s — extrapolated.\n")
COST01 = {}
p('| stack | no waiting: stack / stack+DB | 0.1 s: stack / stack+DB | 1 s: stack / stack+DB | 10 s (extrapolated): stack | memory at 1 s, GB |')
p('|---|---|---|---|---|---:|')
for s in ORDER:
    nw = nowait(s)
    if s not in units:
        continue
    u = units[s]
    cells = []
    if nw is None:
        cells.append('—')
    else:
        v0 = nw[0] / UTIL
        gb0 = nw[2] * v0 / 8 / 1024
        a, e = cost(v0, gb0)
        a2, _ = cost(v0 + nw[1] / UTIL, gb0)
        cells.append(f'${a:.0f} €{e:.0f} / ${a2:.0f}')
    for w, cpu, dbc in ((0.1, u['cpu01'], u['db01']), (1, u['cpu1'], u['db1'])):
        v = cpu / UTIL
        gb = mem_mb(s, 1000, w, v) / 1024
        a, e = cost(v, gb)
        a2, _ = cost(v + dbc / UTIL, gb)
        cells.append(f'${a:.0f} €{e:.0f} / ${a2:.0f}')
    v = u['cpu1'] / UTIL
    gb10 = mem_mb(s, 1000, 10, v) / 1024
    a, e = cost(v, gb10)
    gb1 = mem_mb(s, 1000, 1, v) / 1024
    p(f"| {NAMES[s]} | " + ' | '.join(cells) + f" | ${a:.0f} €{e:.0f} ({gb10:.0f} GB) | {gb1:.1f} |")
    COST01[s] = (cost(u['cpu01'] / UTIL, mem_mb(s, 1000, 0.1, u['cpu01'] / UTIL) / 1024)[0],
                 cost((u['cpu01'] + u['db01']) / UTIL, mem_mb(s, 1000, 0.1, u['cpu01'] / UTIL) / 1024)[0])

CEIL1 = {}
p('\n## 5. Modelled ceiling of one 8 vCPU / 32 GB server for the stack (Hetzner CCX33), PostgreSQL, req/s\n')
p('Not measured: the lower of the CPU ceiling (7.5 threads / CPU per request) and the memory ceiling (30 GB), assuming CPU per request stays as measured at higher concurrency and nothing else limits first; the database is on a separate server and its connections are not a limit (blocking models go through a pool). The highest measured concurrency is 5000 requests waiting 1 s, i.e. at most ~5000 req/s.\n')
p('| stack | no waiting | 0.1 s | 1 s | 10 s (extrapolated) |')
p('|---|---:|---:|---:|---:|')
for s in ORDER:
    nw = nowait(s)
    if s not in units:
        continue
    cells = []
    for w in (0, 0.1, 1, 10):
        if w == 0 and nw is None:
            cells.append('—')
            continue
        cpu = nw[0] if w == 0 else units[s]['cpu01' if w == 0.1 else 'cpu1']
        r = 7.5 / (cpu / 1000)
        lim = ''
        if w and mem_mb(s, r, w, 8) > 30 * 1024:
            lo, hi = 0.0, r
            for _ in range(60):
                mid = (lo + hi) / 2
                lo, hi = (mid, hi) if mem_mb(s, mid, w, 8) <= 30 * 1024 else (lo, mid)
            r, lim = lo, ' (memory)'
        cells.append(f'{r:,.0f}'.replace(',', ' ') + lim)
        if w == 1:
            CEIL1[s] = (r, lim)
    p(f"| {NAMES[s]} | " + ' | '.join(cells) + ' |')

# ---------------------------------------------------------------- PHP-FPM statement variants
VARIANTS = [('', 'native prepares, direct (the default: pdo_pgsql)'), ('variant-fpm-emulated-', 'emulated prepares, direct'),
            ('variant-fpm-noprep-', 'native, `Pdo\\Pgsql::ATTR_DISABLE_PREPARES`, direct'), ('variant-fpm-pgbouncer-', 'native prepares, through PgBouncer')]
vrows_all = {pre: load(pre)[1] for pre, _ in VARIANTS if pre}
if any(vrows_all.values()):
    p('\n## 6. PHP-FPM statement variants, PostgreSQL, C=50\n')
    p('Median of 3 passes. PgBouncer: transaction mode, `max_prepared_statements` 200; its CPU counts as the stack\'s.\n')
    p('| statements | stack CPU, ms/request | DB CPU, ms/request | sum | req/s |')
    p('|---|---:|---:|---:|---:|')
    for pre, name in VARIANTS:
        runs = M.get(('fpm', 'pgsql', 50)) if not pre else [m(r_) for r_ in vrows_all[pre] if r_['db'] == 'pgsql' and r_['c'] == 50]
        if runs:
            sc, dc = st.median(x['scpu'] for x in runs), st.median(x['dbcpu'] for x in runs)
            p(f"| {name} | {sc:.3f} | {dc:.3f} | {sc + dc:.3f} | {st.median(x['rps'] for x in runs):.0f} |")

# ---------------------------------------------------------------- spread of the passes
sp = sorted((max(x['scpu'] for x in v) - min(x['scpu'] for x in v)) / st.median(x['scpu'] for x in v) * 100 for v in M.values() if len(v) > 1)
if sp:
    p('\n## 7. Spread of the memory series\n')
    p(f"Stack CPU per request, (max − min) / median over the passes of each stack × database × C ({len(sp)} configurations): median {st.median(sp):.1f}%, 90th percentile {sp[int(0.9 * (len(sp) - 1))]:.1f}%, maximum {sp[-1]:.1f}%.\n")
wsp = sorted((max(x['scpu'] for x in v) - min(x['scpu'] for x in v)) / st.median(x['scpu'] for x in v) * 100 for v in W.values() if len(v) > 1)
if wsp:
    p(f"Waiting series, the same measure over its passes ({len(wsp)} configurations): median {st.median(wsp):.1f}%, 90th percentile {wsp[int(0.9 * (len(wsp) - 1))]:.1f}%, maximum {wsp[-1]:.1f}%.\n")

# ---------------------------------------------------------------- headline table (README)
head = ['\n## 0. Headline table (PostgreSQL; copied into the repository README)\n',
        '| stack | CPU per request (50 clients) | modelled $/month for 1000 req/s with a 0.1 s wait: stack / stack + DB | memory per 1000 waiting requests | modelled ceiling, req/s on 8 vCPU with a 1 s wait |',
        '|---|---:|---|---:|---:|']
for s in sorted((s for s in ORDER if s in units and nowait(s)), key=lambda s: nowait(s)[0]):
    a, b = COST01[s]
    r_, lim = CEIL1[s]
    gbk = units[s]['s1'] / 1024
    head.append(f"| {NAMES[s]} | {nowait(s)[0]:.2f} ms | ${a:.0f} / ${b:.0f} | {gbk:.2f} GB | {f'{r_:,.0f}'.replace(',', ' ')}{' (memory-bound)' if lim else ''} |")
out[0:0] = head + ['']

print('# Tables — bare runtimes, October 2026\n\nGenerated by `aggregate.py` from `data/raw/` and `prices.json`; do not edit by hand.\n')
print('\n'.join(out))
