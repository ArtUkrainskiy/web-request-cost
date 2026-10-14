#!/bin/bash
# Runs a series: every stack × database (sweep.sh: one start, all concurrencies), REPS passes,
# each pass in its own shuffled order (seeded). Failed sweeps are logged and retried once.
#   SERIES=memory STACK_CPUS=8-11,24-27 LOAD_CPUS=6-7,22-23 CONC="1 10 50 200" [REPS=1] ./matrix.sh
# Output: results/<series>-<date>.jsonl and .log next to it.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
: "${SERIES:?}" "${STACK_CPUS:?}" "${LOAD_CPUS:?}" "${CONC:?}"
REPS=${REPS:-1}
STACKS=${STACKS:-fpm franken rr swoole go node-http node-fastify python rust ruby java dotnet}
DBS=${DBS:-pgsql mysql}
mkdir -p "$DIR/results"
OUT=$DIR/results/$SERIES-$(date +%Y%m%d-%H%M).jsonl
LOG=${OUT%.jsonl}.log
export STACK_CPUS LOAD_CPUS OUT

configs=()
for st in $STACKS; do for db in $DBS; do configs+=("$st $db"); done; done
total=$(( ${#configs[@]} * REPS ))
echo "series $SERIES: ${#configs[@]} stack x db sweeps (C = $CONC) x $REPS passes, stack on $STACK_CPUS -> $OUT" | tee "$LOG"

retry=()
n=0
for rep in $(seq 1 "$REPS"); do
	mapfile -t order < <(printf '%s\n' "${configs[@]}" | python3 -c "import random, sys; l = sys.stdin.read().splitlines(); random.Random($rep).shuffle(l); print('\n'.join(l))")
	for cfg in "${order[@]}"; do
		n=$((n + 1))
		set -- $cfg
		if bash "$DIR/sweep.sh" "$1" "$2" "$CONC" > /dev/null 2> "$LOG.last"; then
			echo "$(date +%T) [$n/$total] pass $rep $cfg ok" >> "$LOG"
		else
			echo "$(date +%T) [$n/$total] pass $rep $cfg REJECTED: $(tail -c 300 "$LOG.last" | tr '\n' ' ')" >> "$LOG"
			retry+=("$cfg")
		fi
	done
done
for cfg in "${retry[@]}"; do
	set -- $cfg
	if bash "$DIR/sweep.sh" "$1" "$2" "$CONC" > /dev/null 2> "$LOG.last"; then
		echo "$(date +%T) retry $cfg ok" >> "$LOG"
	else
		echo "$(date +%T) retry $cfg REJECTED AGAIN: $(tail -c 300 "$LOG.last" | tr '\n' ' ')" >> "$LOG"
	fi
done
rm -f "$LOG.last"
echo "done: $(wc -l < "$OUT") runs recorded" | tee -a "$LOG"
