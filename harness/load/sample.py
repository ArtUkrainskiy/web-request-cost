#!/usr/bin/env python3
# Samples the cgroups of the stack's containers and of the database containers while a load
# runs. Writes the cgroup directories of each group into <ready_file> after the first sample (for
# cgcpu.py), stops when <stop_file> appears.
#   sample.py <interval_ms> <ready_file> <stop_file> <stack container> [...] -- <db container> [...]
# Prints one JSON line: per group (stack, each db) the sum over its containers of
#   memory.current (median, max of samples), memory.stat anon/file/shmem/kernel/sock at the
#   max sample, memory.peak at the end (since container start), CPU seconds between the
#   first and the last sample.
import json, os, statistics, subprocess, sys, time

interval = int(sys.argv[1]) / 1000
ready_file, stop_file = sys.argv[2], sys.argv[3]
args = sys.argv[4:]
sep = args.index('--')
groups = {'stack': args[:sep]}
for name in args[sep + 1:]:
    groups[name] = [name]


def cgroup_dir(container):
    cid = subprocess.check_output(['docker', 'inspect', '-f', '{{.Id}}', container], text=True).strip()
    for d in (f'/sys/fs/cgroup/system.slice/docker-{cid}.scope', f'/sys/fs/cgroup/docker/{cid}'):
        if os.path.exists(d + '/memory.current'):
            return d
    raise SystemExit(f'no cgroup for {container}')


dirs = {g: [cgroup_dir(c) for c in cs] for g, cs in groups.items()}


def read_int(path):
    with open(path) as f:
        return int(f.read().split()[0])


def stat(d):
    out = {}
    with open(d + '/memory.stat') as f:
        for line in f:
            k, v = line.split()
            if k in ('anon', 'file', 'shmem', 'kernel', 'sock'):
                out[k] = int(v)
    return out


def cpu_s(d):
    with open(d + '/cpu.stat') as f:
        for line in f:
            if line.startswith('usage_usec'):
                return int(line.split()[1]) / 1e6
    raise SystemExit(f'no usage_usec in {d}')


samples = {g: [] for g in dirs}
at_max = {g: None for g in dirs}
cpu0 = {g: sum(cpu_s(d) for d in ds) for g, ds in dirs.items()}
t0 = time.monotonic()
first = True
while True:
    for g, ds in dirs.items():
        cur = sum(read_int(d + '/memory.current') for d in ds)
        samples[g].append(cur)
        if cur >= max(samples[g]):
            st = {}
            for d in ds:
                for k, v in stat(d).items():
                    st[k] = st.get(k, 0) + v
            at_max[g] = st
    if first:
        with open(ready_file + '.tmp', 'w') as f:
            json.dump(dirs, f)
        os.rename(ready_file + '.tmp', ready_file)
        first = False
    if os.path.exists(stop_file):
        break
    time.sleep(interval)
seconds = time.monotonic() - t0
result = {'samples': len(samples['stack']), 'seconds': round(seconds, 2)}
for g, ds in dirs.items():
    result[g] = {
        'containers': len(ds),
        'mem_median': int(statistics.median(samples[g])), 'mem_max': max(samples[g]),
        'mem_stat_at_max': at_max[g],
        'mem_peak_since_start': sum(read_int(d + '/memory.peak') for d in ds),
        'cpu_s': round(sum(cpu_s(d) for d in ds) - cpu0[g], 3),
    }
print(json.dumps(result))
