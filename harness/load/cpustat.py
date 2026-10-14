#!/usr/bin/env python3
# Busy CPU per group of host CPUs between two /proc/stat snapshots.
#   cpustat.py snap > a; ...; cpustat.py snap > b
#   cpustat.py diff a b name=0-3,16-19 [name=...]   -> {"name": busy cores, ..., "other": busy cores}
import json, os, sys


def parse_set(s):
    out = set()
    for part in s.split(','):
        if part:
            a, _, b = part.partition('-')
            out.update(range(int(a), int(b or a) + 1))
    return out


FIELDS = ('user', 'nice', 'system', 'idle', 'iowait', 'irq', 'softirq', 'steal')


def snap():
    cpus = {}
    for line in open('/proc/stat'):
        f = line.split()
        if f[0].startswith('cpu') and f[0] != 'cpu':
            cpus[int(f[0][3:])] = list(map(int, f[1:9]))
    return cpus


if sys.argv[1] == 'snap':
    print(json.dumps(snap()))
else:
    a, b = (json.load(open(p)) for p in sys.argv[2:4])
    groups = {k: parse_set(v) for k, v in (g.split('=', 1) for g in sys.argv[4:])}
    named = set().union(*groups.values()) if groups else set()
    groups['other'] = {int(c) for c in a} - named
    out = {}
    for name, cpus in groups.items():
        d = [0] * 8
        for c in cpus:
            for i, (x, y) in enumerate(zip(a[str(c)], b[str(c)])):
                d[i] += y - x
        total = sum(d) / len(cpus) if cpus else 0
        busy = sum(d) - d[3] - d[4]  # idle and iowait excluded
        out[name] = round(busy / total, 2) if total else 0  # busy cores
        if name != 'other' and total and os.environ.get('PROBES'):
            out[name + '.detail'] = {k: round(v / total, 3) for k, v in zip(FIELDS, d) if k not in ('idle',)}  # cores
    print(json.dumps(out))
