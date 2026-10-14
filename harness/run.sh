#!/bin/bash
# One measured configuration. Checks the databases, starts the stack, checks its responses,
# warms up, then loads it with wrk (Zipf request list) while sampling the cgroups of the
# stack's containers and of the databases. Rejects the run (exit 1, nothing appended) on
# connection errors, any 5xx or unexpected status, an unexpected share of 401, or errors in the stack's logs.
#   STACK_CPUS=8-11,24-27 LOAD_CPUS=4-7,20-23 OUT=results.jsonl [DURATION=10] [WARMUP=3] ./run.sh <stack> <pgsql|mysql> <concurrency>
# With NO_UP=1 and STACK_NAMES it measures a stack that is already running (see sweep.sh).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
: "${STACK_CPUS:?set STACK_CPUS}" "${LOAD_CPUS:?set LOAD_CPUS}" "${OUT:?set OUT}"
export STACK_CPUS
stack=$1
db=$2
c=$3
DURATION=${DURATION:-10}
WARMUP=${WARMUP:-3}
VERIFY_LIST=$DIR/../spec/requests/requests.txt
LOAD_LIST=$DIR/../spec/requests/requests-zipf.txt
EXPECT=${EXPECT:-4cb01d080299bb64ea71f0564c9fa067aedb24ca576a85d17f53c19ab1c7f09d}
declare -A PORT=([fpm]=8080 [go]=8081 [node-http]=8082 [node-fastify]=8082 [franken]=8083 [rr]=8084 [swoole]=8085 [python]=8096 [rust]=8097 [ruby]=8098 [java]=8099 [dotnet]=8100)
port=${PORT[$stack]:?unknown stack}
threads=$(( c < 4 ? c : 4 ))
{ [ -s ~/.nvm/nvm.sh ] && . ~/.nvm/nvm.sh >/dev/null && nvm use 24.22.0 >/dev/null; } || true
fail() { echo "REJECTED $stack $db c=$c: $*" >&2; exit 1; }
# LOAD_SSH / DB_SSH: run the load generator / the database commands on another host (same paths there);
# STACK_HOST: the stack's address as the load generator reaches it. PROBES=1 adds diagnostics to the record: TCP
# segments to the databases (net), user/system CPU and context switches per cgroup, the host CPU breakdown.
onload() { if [ -n "$LOAD_SSH" ]; then ssh -o BatchMode=yes $LOAD_SSH "ulimit -n \$(ulimit -Hn); $1"; else bash -c "$1"; fi; }
ondb() { if [ -n "$DB_SSH" ]; then ssh -o BatchMode=yes $DB_SSH "$1"; else bash -c "$1"; fi; }
NODE=${LOAD_NODE:-node}

dbinfo=$(ondb "$DIR/stack/db.sh check ${DB_MIN:-$((c + 40))}") || fail "database check: $dbinfo"
ulimit -n "$(ulimit -Hn)"
base=http://${STACK_HOST:-127.0.0.1}:$port
if [ -n "$NO_UP" ]; then
	# sweep.sh started the stack and checked its responses; it passes the container names.
	names=${STACK_NAMES:?}
else
	"$DIR/stack/down.sh"
	trap '"$DIR/stack/down.sh"' EXIT
	names=$(timeout 60 "$DIR/stack/up.sh" "$stack" "$db") || fail "stack did not start"
	check=$(onload "timeout 300 taskset -c $LOAD_CPUS $NODE $DIR/load/verify.mjs $base $VERIFY_LIST 2000 8 canon")
	case "$check" in *"$EXPECT"*) ;; *) fail "responses differ: $check" ;; esac
fi

onload "REQUESTS=$LOAD_LIST timeout $((WARMUP + 60)) taskset -c $LOAD_CPUS wrk -t$threads -c$c -d${WARMUP}s --timeout 30s -s $DIR/load/wrk.lua $base" > /tmp/blog-warmup.txt
w0=$(sed -n 's/^WRKJSON //p' /tmp/blog-warmup.txt)
python3 -c "import json,sys; w=json.loads(sys.argv[1]); sys.exit(0 if w['errors']==0 else 1)" "$w0" || fail "warmup errors: $w0"
# Requests still in flight when the warm-up ends must finish before the measured window starts.
pause=$(python3 -c "import re,sys; m=re.search(r'ms=(\d+)', sys.argv[1]); print(int(m.group(1)) / 1000 + 1 if m else 1)" "${UPSTREAM:-}")
read -t "$pause" < /dev/zero || true

tmp=$(mktemp -d)
taskset -c "$LOAD_CPUS" python3 "$DIR/load/sample.py" 200 "$tmp/ready" "$tmp/stop" $names -- $([ -z "$DB_SSH" ] && echo blog-pg blog-mysql) > "$tmp/sample.json" &
spid=$!
timeout 30 bash -c "until [ -e $tmp/ready ]; do read -t 0.05 < /dev/zero || true; done" || fail "sampler did not start"
python3 "$DIR/load/cpustat.py" snap > "$tmp/cpu0"
[ -n "$PROBES" ] && python3 "$DIR/load/netseg.py" snap "$port" > "$tmp/net0"
python3 "$DIR/load/cgcpu.py" snap "$tmp/ready" > "$tmp/cg0"
[ -n "$DB_SSH" ] && ondb "PROBES=$PROBES python3 $DIR/load/cgcpu.py snapc blog-pg blog-mysql" > "$tmp/db0"
onload "REQUESTS=$LOAD_LIST timeout $((DURATION + 90)) taskset -c $LOAD_CPUS wrk -t$threads -c$c -d${DURATION}s --timeout 30s --latency -s $DIR/load/wrk.lua $base" > "$tmp/wrk.txt"
python3 "$DIR/load/cgcpu.py" snap "$tmp/ready" > "$tmp/cg1"
[ -n "$PROBES" ] && python3 "$DIR/load/netseg.py" snap "$port" > "$tmp/net1"
[ -n "$DB_SSH" ] && ondb "PROBES=$PROBES python3 $DIR/load/cgcpu.py snapc blog-pg blog-mysql" > "$tmp/db1"
python3 "$DIR/load/cpustat.py" snap > "$tmp/cpu1"
touch "$tmp/stop"
wait "$spid"
cpuwin=$(python3 "$DIR/load/cgcpu.py" diff "$tmp/cg0" "$tmp/cg1")
net=$([ -n "$PROBES" ] && python3 "$DIR/load/netseg.py" diff "$tmp/net0" "$tmp/net1" || echo null)
if [ -n "$DB_SSH" ]; then
	cpuwin=$(python3 -c "import json,sys; a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); b.pop('seconds'); a.update(b); print(json.dumps(a))" "$cpuwin" "$(python3 "$DIR/load/cgcpu.py" diff "$tmp/db0" "$tmp/db1")")
fi
# TLS sessions of the stack to MySQL (PostgreSQL runs with ssl=off).
tls=$(ondb "docker exec blog-mysql mysql -h127.0.0.1 -P53340 -uroot -pbench -Nse \"SELECT COUNT(*) FROM performance_schema.threads t JOIN performance_schema.status_by_thread s ON s.THREAD_ID = t.THREAD_ID AND s.VARIABLE_NAME = 'Ssl_version' WHERE t.TYPE = 'FOREGROUND' AND t.PROCESSLIST_ID <> CONNECTION_ID() AND s.VARIABLE_VALUE <> ''\" 2>/dev/null" || echo null)
# Effective configuration: command, environment and image of each container, and the files up.sh wrote.
config=$(python3 - ${RUN_DIR:-/tmp/blog-stack} $names <<'PY'
import glob, json, os, subprocess, sys
run, names = sys.argv[1], sys.argv[2:]
out = {'containers': {}, 'files': {}}
for n in names:
    c = json.loads(subprocess.check_output(['docker', 'inspect', n]))[0]
    out['containers'][n] = {'image': c['Config']['Image'], 'image_id': c['Image'], 'cmd': c['Config']['Cmd'],
                            'env': [e for e in c['Config']['Env'] if not e.startswith(('PATH=', 'HOSTNAME='))]}
for p in sorted(glob.glob(run + '/*')):
    if os.path.isfile(p) and p.endswith(('.conf', '.ini', '.yaml', 'Caddyfile')):
        out['files'][os.path.basename(p)] = open(p).read()
print(json.dumps(out))
PY
)
if [ -n "$LOAD_SSH" ]; then  # this host runs only the stack
	cpubusy=$(python3 "$DIR/load/cpustat.py" diff "$tmp/cpu0" "$tmp/cpu1" stack="$STACK_CPUS")
else
	cpubusy=$(python3 "$DIR/load/cpustat.py" diff "$tmp/cpu0" "$tmp/cpu1" stack="$STACK_CPUS" load="$LOAD_CPUS" db="${DB_CPUS:-0-5,16-21}" ${UPSTREAM_CPUS:+upstream=$UPSTREAM_CPUS})
fi
w=$(sed -n 's/^WRKJSON //p' "$tmp/wrk.txt")
s=$(cat "$tmp/sample.json")
rm -rf "$tmp"

python3 - "$w" "$LOAD_LIST" <<'PY' || fail "load result: $w"
import json, math, sys
w = json.loads(sys.argv[1])
lines = open(sys.argv[2]).read().split('\n')
p = sum(1 for l in lines if l.endswith(' tok-unknown')) / sum(1 for l in lines if l)
n = w['requests']
tolerance = max(0.005, 4 * math.sqrt(p * (1 - p) / n))
ok = w['errors'] == 0 and w['s5xx'] == 0 and w['s404'] == 0 and w['sother'] == 0 and abs(w['s401'] / n - p) <= tolerance
sys.exit(0 if ok else 1)
PY
logs=$(for n in $names; do docker logs "$n" 2>&1; done; cat "${RUN_DIR:-/tmp/blog-stack}"/*.log 2>/dev/null || true)
if echo "$logs" | command grep -qiE 'fatal|panic|uncaught|exception|"level":"error"| ERROR |error: |worker .* exited'; then
	fail "errors in logs: $(echo "$logs" | command grep -iE 'fatal|panic|uncaught|exception|"level":"error"| ERROR |error: |worker .* exited' | head -3)"
fi

affinity=$(for n in $names; do docker inspect -f '{{.HostConfig.CpusetCpus}}' "$n"; done | sort -u | tr '\n' ' ')
printf '{"stack":"%s","db":"%s","c":%d,"duration":%d,"warmup":%d,"containers":"%s","stack_cpus":"%s","container_cpus":"%s","load_cpus":"%s","host":"%s","time":"%s","env":"%s","php_workers":"%s","stmt_cache":"%s","upstream":"%s","via_bouncer":"%s","pdo_emulate":"%s","pause":%s,"governor":"%s","cpu_busy":%s,"cpu_window":%s,%s"db_tls_sessions":%s,"dbinfo":%s,"wrk":%s,"sample":%s,"config":%s}\n' \
	"$stack" "$db" "$c" "$DURATION" "$WARMUP" "${names% }" "$STACK_CPUS" "${affinity% }" "$LOAD_CPUS" "$(hostname)" "$(date -Is)" "${GOENV:-}${PHP_INI_EXTRA:+ PHP_INI_EXTRA=$PHP_INI_EXTRA}${POOL:+ POOL=$POOL}${SWOOLE_POOL:+ SWOOLE_POOL=$SWOOLE_POOL}${DSN_SUFFIX:+ DSN_SUFFIX=$DSN_SUFFIX}${PHP_ZTS_BUILD:+ PHP_ZTS_BUILD=$PHP_ZTS_BUILD}" "${PHP_WORKERS:-default}" "${STMT_CACHE:-}" "${UPSTREAM:-}" "${VIA_BOUNCER:-}" "${PDO_EMULATE:-}" "$pause" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference /sys/devices/system/cpu/cpufreq/boost 2>/dev/null | paste -sd/)" "$cpubusy" "$cpuwin" "$([ -n "$PROBES" ] && echo "\"net\":$net,")" "$tls" "$dbinfo" "$w" "$s" "$config" | tee -a "$OUT"
