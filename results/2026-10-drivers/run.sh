#!/bin/bash
# Driver settings within one stack: default against one changed connection-string option, same stack, same
# database, 2000 req/s over 48 connections. Every pass runs the six configurations in a new shuffled order.
#   PASSES=3 ./run.sh          (from this folder; the harness is ../../harness)
set -u
PASSES=${PASSES:-3}
cd "$(dirname "$0")/../../harness"
export STACK_CPUS=8-11,24-27 LOAD_CPUS=6-7,22-23 CONC=50 RATES=2000 WARMUP=15 DURATION=20 REPS=1
configs=(
	"go pgsql "
	"go pgsql ?default_query_exec_mode=exec"
	"go mysql "
	"go mysql ?interpolateParams=true"
	"dotnet pgsql "
	"dotnet pgsql ;Max Auto Prepare=20"
)
for pass in $(seq 1 "$PASSES"); do
	mapfile -t order < <(printf '%s\n' "${configs[@]}" | python3 -c "import random, sys; l = sys.stdin.read().splitlines(); random.Random($pass).shuffle(l); print('\n'.join(l))")
	for c in "${order[@]}"; do
		read -r st db suffix <<< "$c"
		echo "pass $pass: $st $db ${suffix:-default}"
		SERIES=drivers-$st-$db STACKS=$st DBS=$db DSN_SUFFIX="$suffix" bash ./matrix.sh > /dev/null
	done
done
echo done
