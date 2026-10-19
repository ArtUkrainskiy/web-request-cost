#!/bin/bash
# FrankenPHP + MySQL with mysqlnd statistics on (the default), off, and on with atomic counters (mysqlnd-atomic-php-8.5.11.patch).
# Variants alternate within each pass, in reverse order on even passes. Two series per pass: 50 clients closed loop
# (the "memory" settings of results/2026-10) and fixed 1000 / 2000 / 4000 req/s over 48 connections (the "rate" settings).
#   ATOMIC=.build/php85-zts-atomic PASSES=3 results/2026-10-mysqlnd/run.sh      (from the repository root)
# ATOMIC: a copy of .build/php85-zts with the patch applied, reconfigured (./config.nice) and rebuilt.
# Output: harness/results/mysqlnd-<date>/<series>-<variant>.jsonl and run.log.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
H=$ROOT/harness
cd "$H"
g=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference /sys/devices/system/cpu/cpufreq/boost | paste -sd/)
[ "$g" = performance/performance/1 ] || { echo "governor $g, the published series ran on performance/performance/1" >&2; exit 1; }
export STACK_CPUS=${STACK_CPUS:-8-11,24-27} LOAD_CPUS=${LOAD_CPUS:-6-7,22-23}
ATOMIC=$(readlink -f "$ROOT/${ATOMIC:-.build/php85-zts-atomic}")
OUTDIR=$H/results/mysqlnd-$(date +%Y%m%d-%H%M)
mkdir -p "$OUTDIR"
LOG=$OUTDIR/run.log
variant() {   # <variant> <series>
	local v=$1 series=$2 extra=() rates=
	case $v in
		stats-on) ;;
		stats-off) extra=(PHP_INI_EXTRA=mysqlnd.collect_statistics=0) ;;
		atomic-on) extra=(PHP_ZTS_BUILD=$ATOMIC) ;;
	esac
	if [ "$series" = rate ]; then rates="1000 2000 4000"; export WARMUP=15 DURATION=20; else unset WARMUP DURATION; fi
	if env "${extra[@]}" OUT="$OUTDIR/$series-$v.jsonl" RATES="$rates" bash "$H/sweep.sh" franken mysql 50 > /dev/null 2> "$OUTDIR/last.err"; then
		echo "$(date +%T) $series $v ok" | tee -a "$LOG"
	else
		echo "$(date +%T) $series $v REJECTED: $(tail -c 300 "$OUTDIR/last.err" | tr '\n' ' ')" | tee -a "$LOG"
	fi
}
echo "start $(date -Is) passes=${PASSES:-3} libphp $(sha256sum "$ROOT/.build/php85-zts/libs/libphp.so" | cut -c1-16) atomic $(sha256sum "$ATOMIC/libs/libphp.so" | cut -c1-16)" | tee "$LOG"
for pass in $(seq 1 "${PASSES:-3}"); do
	if [ $((pass % 2)) = 1 ]; then order="stats-on stats-off atomic-on"; else order="atomic-on stats-off stats-on"; fi
	for series in memory rate; do
		for v in $order; do echo "pass $pass" >> "$LOG"; variant "$v" "$series"; done
	done
done
echo "done $(date -Is)" | tee -a "$LOG"
