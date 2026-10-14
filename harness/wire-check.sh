#!/bin/bash
# What each stack's driver sends to the databases for 10 requests of /posts?page=1 (4 statements each):
# PostgreSQL statement log (log_statement=all, switched on for the check and reset after it) and the
# change of MySQL's Com_* counters. Prints one line per stack and database. No load.
#   STACK_CPUS=... [STACKS="fpm go ..."] ./wire-check.sh
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
: "${STACK_CPUS:?set STACK_CPUS}"
STACKS=${STACKS:-fpm franken rr swoole go node-http python rust ruby java dotnet}
declare -A PORT=([fpm]=8080 [go]=8081 [node-http]=8082 [node-fastify]=8082 [franken]=8083 [rr]=8084 [swoole]=8085 [python]=8096 [rust]=8097 [ruby]=8098 [java]=8099 [dotnet]=8100)
pg() { docker exec blog-pg psql -h 127.0.0.1 -p 55440 -U postgres -d bench -Atc "$1"; }
my() { docker exec blog-mysql mysql -h127.0.0.1 -P53340 -uroot -pbench -Nse "SHOW GLOBAL STATUS LIKE 'Com\_%'" 2>/dev/null | sort; }
req() { for i in $(seq 1 "$1"); do curl -s -o /dev/null -H "Authorization: Bearer tok-$i" "http://127.0.0.1:${PORT[$st]}/posts?page=1"; done; }
tmp=$(mktemp -d)
pg "ALTER SYSTEM SET log_statement = 'all'" >/dev/null; pg "SELECT pg_reload_conf()" >/dev/null
trap 'pg "ALTER SYSTEM RESET log_statement" >/dev/null; pg "SELECT pg_reload_conf()" >/dev/null; "$DIR/stack/down.sh"; rm -rf "$tmp"' EXIT
for st in $STACKS; do
	for db in pgsql mysql; do
		"$DIR/stack/down.sh"
		timeout 60 "$DIR/stack/up.sh" "$st" "$db" >/dev/null
		req 12   # connections opened, statements cached where the driver caches them
		read -t 1 < /dev/zero || true
		since=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ); my > "$tmp/a"
		req 10
		read -t 1 < /dev/zero || true
		if [ "$db" = pgsql ]; then
			l=$(docker logs --since "$since" blog-pg 2>&1 | grep 'LOG:' || true)
			echo "$st pgsql: execute <unnamed> $(echo "$l" | grep -c 'execute <unnamed>'), execute named $(echo "$l" | grep 'execute ' | grep -vc '<unnamed>'), simple statements $(echo "$l" | grep -c 'statement: '), distinct names $(echo "$l" | grep -o 'execute [A-Za-z_0-9]*' | grep -v unnamed | sort -u | wc -l)"
		else
			my > "$tmp/b"
			echo "$st mysql: $(join "$tmp/a" "$tmp/b" | awk '$3 - $2 > 0 && $1 != "Com_show_status" { printf "%s %d  ", substr($1, 5), $3 - $2 }')"
		fi
	done
done
