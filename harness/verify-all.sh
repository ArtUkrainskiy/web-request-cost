#!/bin/bash
# Starts every stack on both databases and checks that each returns the reference responses
# (hash over the first N requests of the list). No load.
#   STACK_CPUS=... [N=2000] [STACKS="fpm go ..."] ./verify-all.sh
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
: "${STACK_CPUS:?set STACK_CPUS}"
N=${N:-2000}
STACKS=${STACKS:-fpm franken rr swoole go node-http node-fastify python rust ruby java dotnet}
EXPECT=${EXPECT:-4cb01d080299bb64ea71f0564c9fa067aedb24ca576a85d17f53c19ab1c7f09d}
{ [ -s ~/.nvm/nvm.sh ] && . ~/.nvm/nvm.sh >/dev/null && nvm use 24.22.0 >/dev/null; } || true
declare -A PORT=([fpm]=8080 [go]=8081 [node-http]=8082 [node-fastify]=8082 [franken]=8083 [rr]=8084 [swoole]=8085 [python]=8096 [rust]=8097 [ruby]=8098 [java]=8099 [dotnet]=8100)
fail=0
for st in $STACKS; do
	for db in pgsql mysql; do
		"$DIR/stack/down.sh"
		if ! names=$(timeout 60 "$DIR/stack/up.sh" "$st" "$db"); then
			echo "$st $db: start failed"
			fail=1
			continue
		fi
		t0=$(date +%s%N)
		out=$(if [ -n "$LOAD_SSH" ]; then ssh -o BatchMode=yes $LOAD_SSH "timeout 300 ${LOAD_NODE:-node} $DIR/load/verify.mjs http://${STACK_HOST:-127.0.0.1}:${PORT[$st]} $DIR/../spec/requests/requests.txt $N 8 canon"; else timeout 300 node "$DIR/load/verify.mjs" "http://127.0.0.1:${PORT[$st]}" "$DIR/../spec/requests/requests.txt" "$N" 8 canon; fi)
		case "$out" in *"$EXPECT"*) r=ok ;; *) r=MISMATCH; fail=1 ;; esac
		echo "$st $db [$names] $r $(( ($(date +%s%N) - t0) / 1000000 )) ms $out"
	done
done
"$DIR/stack/down.sh"
exit $fail
