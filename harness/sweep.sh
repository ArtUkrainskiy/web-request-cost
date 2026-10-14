#!/bin/bash
# Starts one stack, checks its responses once, then measures it at each concurrency in turn.
#   STACK_CPUS=... LOAD_CPUS=... OUT=... [RATES="1000 2000 4000"] ./sweep.sh <stack> <pgsql|mysql> "<concurrency list>"
# With RATES: every concurrency at every fixed request rate (run.sh RATE), rates in the given order.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
: "${STACK_CPUS:?}" "${LOAD_CPUS:?}" "${OUT:?}"
export STACK_CPUS LOAD_CPUS OUT
stack=$1
db=$2
declare -A PORT=([fpm]=8080 [go]=8081 [node-http]=8082 [node-fastify]=8082 [franken]=8083 [rr]=8084 [swoole]=8085 [python]=8096 [rust]=8097 [ruby]=8098 [java]=8099 [dotnet]=8100)
EXPECT=${EXPECT:-4cb01d080299bb64ea71f0564c9fa067aedb24ca576a85d17f53c19ab1c7f09d}
{ [ -s ~/.nvm/nvm.sh ] && . ~/.nvm/nvm.sh >/dev/null && nvm use 24.22.0 >/dev/null; } || true
"$DIR/stack/down.sh"
trap '"$DIR/stack/down.sh"' EXIT
names=$(timeout 60 "$DIR/stack/up.sh" "$stack" "$db") || { echo "REJECTED $stack $db: stack did not start" >&2; exit 1; }
onload() { if [ -n "$LOAD_SSH" ]; then ssh -o BatchMode=yes $LOAD_SSH "$1"; else bash -c "$1"; fi; }
check=$(onload "timeout 300 taskset -c $LOAD_CPUS ${LOAD_NODE:-node} $DIR/load/verify.mjs http://${STACK_HOST:-127.0.0.1}:${PORT[$stack]} $DIR/../spec/requests/requests.txt ${VERIFY_N:-2000} ${VERIFY_CONC:-8} canon")
case "$check" in *"$EXPECT"*) ;; *) echo "REJECTED $stack $db: responses differ: $check" >&2; exit 1 ;; esac
status=0
for c in $3; do
	for r in ${RATES:-none}; do
		[ "$r" = none ] && r=
		RATE=$r NO_UP=1 STACK_NAMES="$names" bash "$DIR/run.sh" "$stack" "$db" "$c" > /dev/null || status=1
	done
done
exit $status
