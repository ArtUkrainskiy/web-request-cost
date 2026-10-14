#!/bin/bash
# Waiting series (PostgreSQL): every request calls an upstream that answers after WAIT ms.
# Blocking stacks (FPM, FrankenPHP, RoadRunner; Ruby's Puma threads) get as many workers as concurrent requests,
# the PHP ones with PgBouncer in front of PostgreSQL above 250 workers; the other stacks keep their usual processes and pools.
#   [SERIES=wait] [STACKS=...] STACK_CPUS=8-11,24-27 LOAD_CPUS=6-7,22-23 UPSTREAM_CPUS=12-15,28-31 [WAITS="100 1000"]
#   [CONC_BLOCKING="100 1000"] [CONC_ASYNC="100 1000 5000"] ./wait.sh
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
: "${STACK_CPUS:?}" "${LOAD_CPUS:?}" "${UPSTREAM_CPUS:?}"
export STACK_CPUS LOAD_CPUS UPSTREAM_CPUS
mkdir -p "$DIR/results"
export OUT=$DIR/results/${SERIES:-wait}-$(date +%Y%m%d-%H%M).jsonl
LOG=${OUT%.jsonl}.log
WAITS=${WAITS:-100 1000}
CONC_BLOCKING=${CONC_BLOCKING:-100 1000}
CONC_ASYNC=${CONC_ASYNC:-100 1000 5000}
# Responses are checked on the first 200 requests (hash below): with a wait, 2,000 take minutes.
export DB_MIN=60 VERIFY_N=200 VERIFY_CONC=50 EXPECT=75cf48406c2e7a408902b35aef4163b43e6e7509d6309b2866fe8b5523f2c57b
N=$(python3 -c "import sys; print(sum(int(b) - int(a) + 1 if '-' in r else 1 for r in sys.argv[1].split(',') for a, b in [(r.split('-') + r.split('-'))[:2]]))" "$STACK_CPUS")
if [ -n "$LOAD_SSH" ]; then
	ssh -o BatchMode=yes $LOAD_SSH "UPSTREAM_CPUS=$UPSTREAM_CPUS UPSTREAM_LISTEN=${UPSTREAM_HOST:-127.0.0.1} $DIR/stack/upstream.sh start"
	trap 'ssh -o BatchMode=yes $LOAD_SSH "$DIR/stack/upstream.sh stop"' EXIT
else
	"$DIR/stack/upstream.sh" start
	trap '"$DIR/stack/upstream.sh" stop' EXIT
fi
for wait in $WAITS; do
	export UPSTREAM="http://${UPSTREAM_HOST:-127.0.0.1}:9090/wait?ms=$wait"
	for st in ${STACKS:-fpm franken rr swoole go node-http node-fastify python rust ruby java dotnet}; do
		# RoadRunner's HTTP plugin refuses more than 500 workers ("number of workers can't be more than 500").
		case $st in rr) concs=${CONC_RR:-100 500} ;; fpm | franken | ruby) concs=$CONC_BLOCKING ;; *) concs=$CONC_ASYNC ;; esac
		for c in $concs; do
			# A worker per client; PgBouncer only when the workers do not fit into the 300 server connections.
			case $st in fpm | franken | rr) w=$c b=$([ "$c" -gt 250 ] && echo 1 || true) ;; *) w= b= ;; esac
			# Ruby (Puma): a thread per waiting request, like a PHP worker per waiting request; twice as many as
			# the clients per worker, because Puma spreads connections over its workers unevenly.
			rt=$([ "$st" = ruby ] && echo $(( 2 * ((c + N - 1) / N) )) || echo "")
			# JIT runtimes and cold workers need a long warm-up; long waits need a long window.
			warm=${W_WARMUP:-$([ "$c" -ge 500 ] && echo 40 || echo 30)}
			dur=${W_DURATION:-$([ "$wait" -ge 1000 ] && echo 60 || echo 30)}
			if PHP_WORKERS=$w VIA_BOUNCER=$b RUBY_THREADS=$rt WARMUP=$warm DURATION=$dur bash "$DIR/sweep.sh" "$st" pgsql "$c" > /dev/null 2> "$LOG.last"; then
				echo "$(date +%T) wait=$wait $st c=$c ok" >> "$LOG"
			else
				echo "$(date +%T) wait=$wait $st c=$c REJECTED: $(tail -c 300 "$LOG.last" | tr '\n' ' ')" >> "$LOG"
			fi
		done
	done
done
rm -f "$LOG.last"
echo "done: $(wc -l < "$OUT" 2>/dev/null || echo 0) runs -> $OUT" | tee -a "$LOG"
