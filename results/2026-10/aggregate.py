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


def puma_threads(r):
    env = r.get('config', {}).get('containers', {}).get('blog-ruby', {}).get('env', [])
    return next((e.split('=', 1)[1] for e in env if e.startswith('BLOG_THREADS=')), None)


def used(r):
    """Runs the tables use: Ruby without waiting with one Puma thread per database connection (3); the files also
    hold Ruby runs with Puma's default of 5 threads per worker, for comparison."""
    return not (r['stack'] == 'ruby' and not r.get('upstream') and puma_threads(r) == '5')


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
for r in filter(used, rows):
    M.setdefault((r['stack'], r['db'], r['c']), []).append(m(r))
passes = max(len(v) for v in M.values()) if M else 0
p(f'## 1. Equal numbers of clients: memory and CPU, stack on 4 cores (8 threads), C = 1/10/50/200, {passes} passes\n')
p(f'Files: {", ".join("`data/raw/" + f + "`" for f in files)}. Median of the passes, [min–max] in brackets. Memory: anon + shmem + kernel of all the stack\'s containers at the peak of `memory.current` (anon separately). CPU: cgroup CPU seconds between snapshots right before and after wrk, per completed request. C is the `-c` given to wrk; wrk splits the connections over its 4 threads rounded down, so C = 10 and 50 run 8 and 48 connections (C = 1 and 200 run exactly). Ruby: Puma with 3 threads per worker, one per database connection (files `*-ruby-*`); the main files also hold Ruby runs with Puma\'s default of 5 threads, which the tables do not use (section 1b).\n')
for db in ('pgsql', 'mysql'):
    p(f'\n### {db}\n')
    p('| stack | memory, MiB at C=1 / 10 / 50 / 200 | anon at C=50, MiB | req/s at C=50 / 200 | p50 / p99 at C=200, ms | stack CPU at C=50, ms/request | DB CPU at C=50, ms/request | stack / DB cores at C=50 | stack / DB cores at C=200 |')
    p('|---|---|---:|---:|---:|---:|---:|---:|---:|')
    for s in ORDER:
        if (s, db, 200) not in M:
            p(f'| {NAMES[s]} | no data | | | | | | |')
            continue
        mem = ' / '.join(fmt(agg(M[(s, db, c)], 'mem'), '.0f') if (s, db, c) in M else '—' for c in (1, 10, 50, 200))
        a, b = M[(s, db, 200)], M.get((s, db, 50), M[(s, db, 200)])
        p(f"| {NAMES[s]} | {mem} | {fmt(agg(b, 'anon'), '.0f')} | {fmt(agg(b, 'rps'), '.0f')} / {fmt(agg(a, 'rps'), '.0f', True)} | "
          f"{fmt(agg(a, 'p50'), '.1f')} / {fmt(agg(a, 'p99'), '.1f')} | {fmt(agg(b, 'scpu'), '.3f', True)} | "
          f"{fmt(agg(b, 'dbcpu'), '.3f')} | {fmt(agg(b, 'cores'), '.2f')} / {fmt(agg(b, 'dbcores'), '.2f')} | {fmt(agg(a, 'cores'), '.2f')} / {fmt(agg(a, 'dbcores'), '.2f')} |")

# ---------------------------------------------------------------- fixed-rate series
rfiles, rrows = load('rate-')
RT = {}
for r in filter(used, rrows):
    RT.setdefault((r['stack'], r['db'], int(r['rate'])), []).append(m(r))
RATES = sorted({k[2] for k in RT})
if RT:
    rpasses = min(len(v) for v in RT.values())
    p(f'\n## 1a. Fixed request rates: CPU per request at {" / ".join(str(x) for x in RATES)} req/s over 48 connections, at least {rpasses} passes\n')
    p(f'Files: {", ".join("`data/raw/" + f + "`" for f in rfiles)}. wrk2 with a fixed rate (`-R`), warm-up 15 s and 20 s measured at every rate, rates in ascending order on one start of the stack; a run that reaches less than 95% of the rate is rejected (the log lists rejected sweeps, which are rerun). Every stack serves the same load, below the saturation of the database (DB cores at the highest rate in the last column). wrk2 runs with `-c50` and 4 threads, that is 48 connections; it calibrates for about 10 s at the start of each run, which affects its latency statistics, not the CPU window. Median of the passes, [min–max] at 2000 req/s.\n')
    for db in ('pgsql', 'mysql'):
        p(f'\n### {db}\n')
        p(f'| stack | stack CPU, ms/request at {" / ".join(str(x) for x in RATES)} req/s | DB CPU, ms/request | p50 / p99 at {RATES[-1]} req/s, ms | stack / DB cores at {RATES[-1]} req/s |')
        p('|---|---:|---:|---:|---:|')
        for s in ORDER:
            ks = [(s, db, x) for x in RATES]
            if not all(k in RT for k in ks):
                continue
            sc = ' / '.join(fmt(agg(RT[k], 'scpu'), '.3f', k[2] == 2000) for k in ks)
            dc = ' / '.join(fmt(agg(RT[k], 'dbcpu'), '.3f') for k in ks)
            top = RT[ks[-1]]
            p(f"| {NAMES[s]} | {sc} | {dc} | {fmt(agg(top, 'p50'), '.1f')} / {fmt(agg(top, 'p99'), '.1f')} | {fmt(agg(top, 'cores'), '.2f')} / {fmt(agg(top, 'dbcores'), '.2f')} |")

# ---------------------------------------------------------------- checks
cfiles, crows = load('check-')
if crows:
    p('\n## 1b. Checks\n')
    p(f'Files: {", ".join("`data/raw/" + f + "`" for f in cfiles)}. One pass each, PostgreSQL, 50 connections, the fixed-rate settings of section 1a.\n')
    p('.NET: the order of the rates and the thread pool\'s spinning. Stack CPU, ms/request at 1000 / 2000 / 4000 req/s:\n')
    p('| run | stack CPU | DB CPU |')
    p('|---|---:|---:|')
    for f in cfiles:
        if not f.startswith('check-dotnet'):
            continue
        rs = sorted((json.loads(l) for l in open(os.path.join(HERE, 'data/raw', f))), key=lambda r: r['rate'])
        label = {'check-dotnet-rates-descending.jsonl': 'rates 4000, 2000, 1000 on one start', 'check-dotnet-rates-ascending.jsonl': 'rates 1000, 2000, 4000 on one start (as in section 1a)',
                 'check-dotnet-spin-limit-0.jsonl': '`DOTNET_ThreadPool_UnfairSemaphoreSpinLimit=0` (not a default)'}.get(f, f)
        sc = ' / '.join(format(m(r)['scpu'], '.3f') for r in rs)
        dc = ' / '.join(format(m(r)['dbcpu'], '.3f') for r in rs)
        p(f"| {label} | {sc} | {dc} |")
    p('\nThe order does not change the result; without the thread pool\'s spinning, .NET\'s CPU per request is at the level of the other stacks, so the default spends most of it waiting for work when the stack is lightly loaded.\n')
ruby5 = [r for r in rows + rrows if r['stack'] == 'ruby' and not r.get('upstream') and puma_threads(r) == '5']
if ruby5:
    R5 = {}
    for r in ruby5:
        R5.setdefault((r['db'], r['c'], r.get('rate')), []).append(m(r))
    p('Ruby, Puma\'s default of 5 threads per worker with 3 database connections per worker (runs in the main files) against 3 threads (the tables): stack CPU per request and p99 at 200 clients and at 2000 req/s, PostgreSQL.\n')
    p('| threads | stack CPU at 200 clients, ms | p99 at 200 clients, ms | stack CPU at 2000 req/s, ms | p99 at 2000 req/s, ms |')
    p('|---|---:|---:|---:|---:|')
    for label, a, b in (('5', R5.get(('pgsql', 200, None)), R5.get(('pgsql', 50, 2000))), ('3', M.get(('ruby', 'pgsql', 200)), RT.get(('ruby', 'pgsql', 2000)))):
        if a and b:
            p(f"| {label} | {st.median(x['scpu'] for x in a):.3f} | {st.median(x['p99'] for x in a):.0f} | {st.median(x['scpu'] for x in b):.3f} | {st.median(x['p99'] for x in b):.1f} |")

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
p(f'Files: {", ".join("`data/raw/" + f + "`" for f in wfiles)}. Provisioned for the load: blocking models get a worker per client (FPM, FrankenPHP, RoadRunner; the HTTP plugin of RoadRunner accepts at most 500 workers) or 2 × ⌈C/N⌉ threads per Puma worker (Ruby); the PHP blocking models reach PostgreSQL through PgBouncer above 250 workers. Event-loop and virtual-thread stacks keep their usual configuration. Warm-up 30 s (40 s with 500+ clients), pause wait + 1 s, measured 30 s (0.1 s) and 60 s (1 s). Median of {WPASSES} passes; stack CPU with [min–max].\n')
for wait in (100, 1000):
    p(f'\n### {wait} ms wait\n')
    p('| stack | clients | req/s | p50 / p99, ms | stack cores of 8 | stack CPU, ms/request | DB CPU, ms/request | memory, MiB |')
    p('|---|---:|---:|---:|---:|---:|---:|---:|')
    for s in ORDER:
        for c in (100, 500, 1000, 5000):
            if (s, wait, c) in W:
                x = wmed((s, wait, c))
                p(f"| {NAMES[s]} | {c} | {x['rps']:.0f} | {x['p50']:.0f} / {x['p99']:.0f} | {x['cores']:.2f} | {fmt(agg(W[(s, wait, c)], 'scpu'), '.2f', True)} | {x['dbcpu']:.2f} | {x['mem']:.0f} |")

# ---------------------------------------------------------------- derived units
p('\n## 3. Derived values (from section 2)\n')
p('CPU per request: "0.1 s" — the 100 ms × 100 clients run (~1000 req/s with a 0.1 s wait); "1 s" — the 1 s run with the largest number of clients up to 1000 (RoadRunner: 500). Memory per 1000 waits — memory growth at 1 s wait from 100 clients to the largest number up to 1000, and from 1000 to 5000. Base — memory at 100 clients minus 0.1 × growth. In brackets: the slope computed within each pass. The slope mixes concurrency with throughput (more concurrent requests waiting 1 s also means more requests per second) and, for garbage-collected runtimes, the heap policy; it does not carry over to other loads: Node at 100 clients with a 0.1 s wait (about 1000 req/s) uses about 1.35 GiB, twice what the model gives.\n')
p('| stack | stack CPU 0.1 s / 1 s, ms | DB CPU 0.1 s / 1 s, ms | base, MiB | MiB per 1000 waits (up to 1000) | MiB per 1000 waits (1000→5000) |')
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
    lo_hi, per = W[(s, 1000, 100)], W[(s, 1000, hi)]
    slopes = [(b['mem'] - a['mem']) / ((hi - 100) / 1000) for a, b in zip(lo_hi, per)] if hi > 100 else []
    srange = f" [{min(slopes):.0f}–{max(slopes):.0f}]" if len(slopes) > 1 else ''
    p(f"| {NAMES[s]} | {x01['scpu']:.2f} / {x1['scpu']:.2f}{' (' + str(hi) + ')' if hi != 1000 else ''} | {x01['dbcpu']:.2f} / {x1['dbcpu']:.2f} | {base:.0f} | {s1:.0f}{srange} | {s2:.0f}{'' if (s, 1000, 5000) in W else ' (= up to 1000)'} |")

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
UTIL = 0.6  # target CPU utilisation of the stack's and the database's vCPUs in the cost model


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
p(f"Prices (`prices.json`, {prices['retrieved']}): AWS — c7i/m7i/r7i.xlarge on-demand prices decomposed into a vCPU price (${vcpu_h * H:.2f}/month) and a GiB price (${gb_h * H:.2f}/month); Hetzner — €{eur_vcpu:.2f} per vCPU with 4 GB at the CCX33 price after 15 June 2026 (a price at scale, with fractional vCPUs; the smallest server, CCX13, costs €42.99). vCPU = CPU per request / {UTIL:.2f} (a 60% target CPU utilisation). \"Stack\" — the application only (with nginx and PgBouncer where present); \"stack + DB\" — plus PostgreSQL's CPU at the same vCPU price. No waiting — section 1 (C=50, the CPU column shown there); with waiting — section 3; 10 s — extrapolated.\n")
COST01 = {}
p('| stack | no waiting: stack / stack+DB | 0.1 s: stack / stack+DB | 1 s: stack / stack+DB | 10 s (extrapolated): stack | memory at 1 s, GiB |')
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
    p(f"| {NAMES[s]} | " + ' | '.join(cells) + f" | ${a:.0f} €{e:.0f} ({gb10:.0f} GiB) | {gb1:.1f} |")
    COST01[s] = (cost(u['cpu01'] / UTIL, mem_mb(s, 1000, 0.1, u['cpu01'] / UTIL) / 1024)[0],
                 cost((u['cpu01'] + u['db01']) / UTIL, mem_mb(s, 1000, 0.1, u['cpu01'] / UTIL) / 1024)[0])

CEIL1 = {}
p('\n## 5. Modelled ceiling of one 8 vCPU / 32 GB server for the stack (Hetzner CCX33), PostgreSQL, req/s\n')
p('Not measured: the lower of the CPU ceiling (7.5 threads / CPU per request) and the memory ceiling (30 GiB), assuming CPU per request stays as measured at higher concurrency and nothing else limits first. It leaves out the database (its CPU per request is often higher than the stack\'s), the pool of 24 connections and the heap limit of Java (`-Xmx2g`); RoadRunner is capped at its 500 workers (500 / (wait + 0.01 s) req/s). The last column is the highest rate measured with a 1 s wait.\n')
p('| stack | no waiting | 0.1 s | 1 s | 10 s (extrapolated) | measured with a 1 s wait, req/s |')
p('|---|---:|---:|---:|---:|---:|')
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
        if w and s == 'rr' and r > 500 / (w + 0.01):
            r, lim = 500 / (w + 0.01), ' (500 workers)'
        cells.append(f'{r:,.0f}'.replace(',', ' ') + lim)
        if w == 1:
            CEIL1[s] = (r, lim)
    top = max((c for (s_, w_, c) in W if s_ == s and w_ == 1000), default=None)
    mr = wmed((s, 1000, top))['rps'] if top else 0
    p(f"| {NAMES[s]} | " + ' | '.join(cells) + f" | {mr:,.0f} ({top} clients) |".replace(',', ' ', 1))

# ---------------------------------------------------------------- PHP-FPM statement variants
VARIANTS = [('', 'native prepares, direct (the default: pdo_pgsql)'), ('variant-fpm-emulated-', 'emulated prepares, direct'),
            ('variant-fpm-noprep-', 'native, `Pdo\\Pgsql::ATTR_DISABLE_PREPARES`, direct'), ('variant-fpm-pgbouncer-', 'native prepares, through PgBouncer')]
vrows_all = {pre: load(pre)[1] for pre, _ in VARIANTS if pre}
if any(vrows_all.values()):
    p('\n## 6. PHP-FPM statement variants, PostgreSQL, C=50\n')
    p('Median of 3 passes, 50 clients (the database is saturated here, see section 1). PgBouncer: transaction mode, `max_prepared_statements` 200; its CPU counts as the stack\'s. The same comparison of statement modes for the other drivers belongs to the tuning stage.\n')
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
    p("\n## 7. Spread of the passes\n")
    p(f"Stack CPU per request, (max − min) / median over the passes of each stack × database × C ({len(sp)} configurations): median {st.median(sp):.1f}%, 90th percentile {sp[int(0.9 * (len(sp) - 1))]:.1f}%, maximum {sp[-1]:.1f}%.\n")
rsp = sorted((max(x['scpu'] for x in v) - min(x['scpu'] for x in v)) / st.median(x['scpu'] for x in v) * 100 for v in RT.values() if len(v) > 1)
if rsp:
    p(f"Fixed-rate series, the same measure ({len(rsp)} configurations): median {st.median(rsp):.1f}%, 90th percentile {rsp[int(0.9 * (len(rsp) - 1))]:.1f}%, maximum {rsp[-1]:.1f}%.\n")
wsp = sorted((max(x['scpu'] for x in v) - min(x['scpu'] for x in v)) / st.median(x['scpu'] for x in v) * 100 for v in W.values() if len(v) > 1)
if wsp:
    p(f"Waiting series, the same measure over its passes ({len(wsp)} configurations): median {st.median(wsp):.1f}%, 90th percentile {wsp[int(0.9 * (len(wsp) - 1))]:.1f}%, maximum {wsp[-1]:.1f}%.\n")

# ---------------------------------------------------------------- worked example of the model
LIMIT_TEXT = {'(memory)': ' (memory-bound: the rate at which memory reaches 30 GiB)',
              '(500 workers)': ' (RoadRunner\'s 500 workers: 500 / 1.01 s; memory alone would allow more)'}


def example(s):
    u = units[s]
    v = u['cpu01'] / UTIL
    conc = 1000 * (0.1 + 0.01)
    mb = mem_mb(s, 1000, 0.1, v)
    a, _ = cost(v, mb / 1024)
    a2, _ = cost(v + u['db01'] / UTIL, mb / 1024)
    p(f"\n{NAMES[s]}, 1000 req/s with a 0.1 s wait (section 3: stack CPU {u['cpu01']:.3f} ms, DB CPU {u['db01']:.3f} ms, base {u['base']:.0f} MiB, {u['s1']:.0f} MiB per 1000 waiting requests):\n")
    p(f"- vCPU: {u['cpu01']:.3f} ms × 1000 req/s = {u['cpu01']:.3f} CPU-seconds per second; / {UTIL:.2f} = {v:.3f} vCPU.")
    p(f"- Concurrent requests: 1000 × (0.1 + 0.01) s = {conc:.0f}.")
    p(f"- Memory: {u['base']:.0f} MiB × {v:.3f} / 8 + {u['s1']:.0f} MiB × {conc:.0f} / 1000 = {mb:.0f} MiB = {mb / 1024:.3f} GiB.")
    p(f"- Stack: {v:.3f} × ${vcpu_h * H:.2f} + {mb / 1024:.3f} × ${gb_h * H:.2f} = ${a:.2f} per month (section 4: ${a:.0f}).")
    p(f"- Stack + DB: ({u['cpu01']:.3f} + {u['db01']:.3f}) / {UTIL:.2f} × ${vcpu_h * H:.2f} + {mb / 1024:.3f} × ${gb_h * H:.2f} = ${a2:.2f} (section 4: ${a2:.0f}).")
    r = 7.5 / (u['cpu1'] / 1000)
    conc1 = r * 1.01
    mb8 = mem_mb(s, r, 1, 8)
    n = lambda x: f'{x:,.0f}'.replace(',', ' ')
    p(f"- Ceiling with a 1 s wait: CPU limit 7.5 / {u['cpu1'] / 1000:.6f} s = {n(r)} req/s; memory at that rate ({n(conc1)} concurrent requests) {mb8 / 1024:.1f} GiB {'≤' if mb8 <= 30 * 1024 else '>'} 30 GiB, so the ceiling is {n(CEIL1[s][0])} req/s{LIMIT_TEXT.get(CEIL1[s][1].strip(), '')}.")


p('\n## 8. Worked example of the model (sections 4 and 5)\n')
p(f"Prices: the hourly prices of c7i/m7i/r7i.xlarge (4 vCPU with 8, 16 and 32 GiB) fitted as vCPU × a + GiB × b give ${vcpu_h * H:.2f} per vCPU and ${gb_h * H:.2f} per GiB per month ({H} hours). vCPU = CPU-seconds per second / {UTIL:.2f} (a 60% target CPU utilisation). Concurrent requests = rate × (wait + 0.01 s). Memory = base × vCPU / 8 + slope × concurrent requests / 1000 (above 1000 concurrent requests, the slope from 1000 to 5000). Ceiling = the lower of 7.5 / CPU per request and the rate at which memory on 8 vCPU reaches 30 GiB.")
example('fpm')
example('rr')

# ---------------------------------------------------------------- headline table (README)
def c50(s, db):
    runs = RT.get((s, db, 2000)) or M.get((s, db, 50))
    if not runs:
        return None
    sc = st.median(x['scpu'] for x in runs)
    return sc, sc + st.median(x['dbcpu'] for x in runs)


def sig2(x):
    return f"{float(f'{x:.2g}'):,.0f}".replace(',', ' ')


def total(s):
    pg = c50(s, 'pgsql')
    return pg[1] if pg else 99


keep = sorted((s for s in ORDER if s in units and c50(s, 'pgsql') and c50(s, 'mysql')), key=total)
head = ['\n## 0. Headline tables (copied into the repository README)\n',
        '### Measured\n',
        'CPU per request: at a fixed 2000 req/s over 48 connections without waiting (section 1a), median of the passes; "DB" is the database server\'s CPU per request. Memory: growth of the stack\'s memory per 1000 concurrent requests that each wait 1 s (PostgreSQL, section 3). Sorted by stack + DB on PostgreSQL.\n',
        '| stack | PostgreSQL, CPU per request: stack / DB / stack + DB | MySQL, CPU per request: stack / DB / stack + DB | memory per 1000 waiting requests |',
        '|---|---:|---:|---:|']
for s in keep:
    pg, my = c50(s, 'pgsql'), c50(s, 'mysql')
    head.append(f"| {NAMES[s]} | {pg[0]:.2f} / {pg[1] - pg[0]:.2f} / {pg[1]:.2f} ms | {my[0]:.2f} / {my[1] - my[0]:.2f} / {my[1]:.2f} ms | {units[s]['s1'] / 1024:.2f} GiB |")
head += ['\n### Modelled (nothing ran on these servers; sections 4 and 8)\n',
         f'1000 req/s with a 0.1 s wait on another service, PostgreSQL: the CPU per request of that run (the stack\'s and the database\'s, section 3 — not the 2000 req/s figures above), vCPU at a {UTIL:.0%} target CPU utilisation, AWS on-demand prices per vCPU and per GiB, fractional vCPUs; "stack + DB" adds only the database\'s CPU.\n',
         '| stack | modelled $/month, 1000 req/s, 0.1 s wait: stack / stack + DB | CPU per request in that run: stack / DB |',
         '|---|---:|---:|']
for s in keep:
    a, b = COST01[s]
    head.append(f"| {NAMES[s]} | ${a:.0f} / ${b:.0f} | {units[s]['cpu01']:.2f} / {units[s]['db01']:.2f} ms |")
out[0:0] = head + ['']

print('# Tables — bare runtimes, October 2026\n\nGenerated by `aggregate.py` from `data/raw/` and `prices.json`; do not edit by hand.\n')
print('\n'.join(out))
