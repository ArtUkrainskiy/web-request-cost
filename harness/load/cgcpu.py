#!/usr/bin/env python3
# CPU seconds of cgroup groups at one moment, and the difference of two such snapshots.
#   cgcpu.py snap <groups.json> > a; ...; cgcpu.py snap <groups.json> > b
#   cgcpu.py snapc <container> ...   (one group per container, resolved with docker inspect; for a remote host)
#   cgcpu.py diff a b   -> {"seconds": wall time between a and b, "<group>": CPU seconds, "<group>.user", "<group>.system", ...}
# groups.json: {"<group>": ["<cgroup dir>", ...]} (sample.py writes it into its ready file).
import json, os, subprocess, sys, time


def cpu_stat(d):
    out = {}
    with open(d + '/cpu.stat') as f:
        for line in f:
            k, v = line.split()
            if k in ('usage_usec', 'user_usec', 'system_usec'):
                out[k] = int(v) / 1e6
    return out


def ctx_switches(d):
    """Voluntary and involuntary context switches summed over the threads of a cgroup."""
    vol = inv = 0
    try:
        tids = open(d + '/cgroup.threads').read().split()
    except OSError:
        return 0, 0
    for tid in tids:
        try:
            for line in open(f'/proc/{tid}/status'):
                if line.startswith('voluntary_ctxt_switches'):
                    vol += int(line.split()[1])
                elif line.startswith('nonvoluntary_ctxt_switches'):
                    inv += int(line.split()[1])
        except OSError:
            pass
    return vol, inv


def cpu_s(d):
    return cpu_stat(d)['usage_usec']


def cgroup_dir(container):
    cid = subprocess.check_output(['docker', 'inspect', '-f', '{{.Id}}', container], text=True).strip()
    for d in (f'/sys/fs/cgroup/system.slice/docker-{cid}.scope', f'/sys/fs/cgroup/docker/{cid}'):
        if os.path.exists(d + '/cpu.stat'):
            return d
    raise SystemExit(f'no cgroup for {container}')


if sys.argv[1] in ('snap', 'snapc'):
    groups = json.load(open(sys.argv[2])) if sys.argv[1] == 'snap' else {c: [cgroup_dir(c)] for c in sys.argv[2:]}
    out = {}
    for g, ds in groups.items():
        st = [cpu_stat(d) for d in ds]
        out[g] = sum(x['usage_usec'] for x in st)
        if os.environ.get('PROBES'):  # diagnostics: user/system split and context switches
            out[g + '.user'] = sum(x['user_usec'] for x in st)
            out[g + '.system'] = sum(x['system_usec'] for x in st)
            cs = [ctx_switches(d) for d in ds]
            out[g + '.ctx_vol'] = sum(v for v, _ in cs)
            out[g + '.ctx_invol'] = sum(i for _, i in cs)
    out['t'] = time.monotonic()
    print(json.dumps(out))
else:
    a, b = (json.load(open(p)) for p in sys.argv[2:4])
    out = {'seconds': round(b['t'] - a['t'], 4)}
    out.update({g: round(b[g] - a[g], 4) for g in a if g != 't'})
    print(json.dumps(out))
