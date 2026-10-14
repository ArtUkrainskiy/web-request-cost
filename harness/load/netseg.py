#!/usr/bin/env python3
# TCP segments and bytes of the established connections of this host's network namespace, from `ss -tin`,
# summed per class: "db" = peer port 55440/53340 (PostgreSQL, MySQL), "client" = local port in PORTS.
#   netseg.py snap <local ports, comma-separated> > a; ...; netseg.py diff a b
# A connection present in both snapshots counts its growth; one opened in between counts all of it;
# one closed in between is lost (pools and keep-alive keep them open).
import json, re, subprocess, sys

DB_PORTS = {55440, 53340}


def snap(ports):
    out = {}
    lines = subprocess.check_output(['ss', '-tinH', 'state', 'established'], text=True).splitlines()
    key = None
    for line in lines:
        if not line.startswith(('\t', ' ')) and len(line.split()) >= 4:
            f = line.split()
            local, peer = f[2], f[3]
            lp, pp = int(local.rsplit(':', 1)[1]), int(peer.rsplit(':', 1)[1])
            cls = 'db' if pp in DB_PORTS else 'client' if lp in ports else None
            key = (cls, local, peer) if cls else None
            continue
        if key:
            v = {k: int(n) for k, n in re.findall(r'\b(segs_out|segs_in|bytes_sent|bytes_received):(\d+)', line)}
            out['|'.join(key)] = v
            key = None
    return out


if sys.argv[1] == 'snap':
    print(json.dumps(snap({int(p) for p in sys.argv[2].split(',')})))
else:
    a, b = (json.load(open(p)) for p in sys.argv[2:4])
    tot = {}
    for k, v in b.items():
        cls = k.split('|')[0]
        base = a.get(k, {})
        t = tot.setdefault(cls, {'conns': 0, 'segs_out': 0, 'segs_in': 0, 'bytes_sent': 0, 'bytes_received': 0})
        t['conns'] += 1
        for f in ('segs_out', 'segs_in', 'bytes_sent', 'bytes_received'):
            t[f] += v.get(f, 0) - base.get(f, 0)
    print(json.dumps(tot))
