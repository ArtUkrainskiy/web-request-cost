#!/bin/bash
# Starts one stack as containers on the host network, all on $STACK_CPUS, and prints their
# names (one line, space-separated) — the sampler sums the cgroups of exactly these.
#   STACK_CPUS=8-11,24-27 ./up.sh <stack> <pgsql|mysql>
#   ./down.sh
# Stacks (implementations/<language>): fpm (nginx + PHP-FPM, persistent PDO; PgBouncer with VIA_BOUNCER=1),
# franken (FrankenPHP worker), rr (RoadRunner), swoole, go (pgxpool / database/sql, pool 24), node-http,
# node-fastify (cluster), python (uvicorn, N processes), rust (hyper, pool 24), ruby (Puma, N workers x ⌈24/N⌉ threads, one per connection),
# java (Jetty 12 on virtual threads, HikariCP 24), dotnet (Kestrel minimal APIs, ADO.NET, pool 24).
# Fixed configuration, independent of the load; see ../../spec/spec.md and ../../docs/rules.md.
set -e
: "${STACK_CPUS:?set STACK_CPUS}"
DIR=$(cd "$(dirname "$0")/.." && pwd)
IMPL=$(cd "$DIR/../implementations" && pwd)
BUILD=${BUILD_DIR:-$(cd "$DIR/.." && pwd)/.build}
UBUNTU=$(. /etc/os-release && echo "$VERSION_ID")
IMG=blog-runtime:$UBUNTU
PHP=$(readlink -f "${PHP_BUILD:-$BUILD/php85-fpm}")
RUN=${RUN_DIR:-/tmp/blog-stack}
stack=$1
db=$2
# DB_HOST: address of the databases; LISTEN_HOST: address the stack listens on (default 127.0.0.1 for both).
DBH=${DB_HOST:-127.0.0.1}
LH=${LISTEN_HOST:-127.0.0.1}
# N = CPUs of the stack; process counts follow it (N=8: FPM 32, FrankenPHP/RoadRunner 16,
# Swoole/Node 8, PgBouncer 4 processes). PHP_WORKERS overrides the FPM, FrankenPHP and RoadRunner count;
# STMT_CACHE=1 keeps PDO statements per connection in the PHP worker stacks (off: PDO's default); PDO prepares
# follow the driver default (PDO_EMULATE overrides it); UPSTREAM=<url> makes every request call that URL after
# authentication; VIA_BOUNCER=1 puts PgBouncer in front of PostgreSQL for FPM, FrankenPHP and RoadRunner;
# SWOOLE_POOL overrides the Swoole pool per worker; POOL the connections per stack (default 24);
# DSN_SUFFIX is appended to the Go and .NET connection strings (variant runs);
# PDO_DISABLE_PREPARES=1 makes FPM on PostgreSQL run statements without named prepared statements; STACK_MEMORY caps each container (default 40g).
N=$(python3 -c "import sys; print(sum(int(b) - int(a) + 1 if '-' in r else 1 for r in sys.argv[1].split(',') for a, b in [(r.split('-') + r.split('-'))[:2]]))" "$STACK_CPUS")
BOUNCERS=$(( N / 2 > 0 ? N / 2 : 1 ))
POOL=${POOL:-24}   # connections per stack (variant runs override)
PER_PROC_POOL=$(( (POOL + N - 1) / N ))   # Node and Swoole: about $POOL connections per stack
rm -rf "$RUN" && mkdir -p "$RUN"
chmod 777 "$RUN"
mkdir -p "$RUN/opcache" && chmod 777 "$RUN/opcache"
# php.ini of every PHP stack (php_ini <build dir> [line ...]): the build's php.ini-production, the OPcache
# settings php.net recommends (https://www.php.net/manual/en/opcache.installation.php), then the stack's lines
# and PHP_INI_EXTRA (space-separated, for variant runs).
php_ini() {
	cat "$1/php.ini-production"
	shift
	printf '%s\n' opcache.memory_consumption=128 opcache.interned_strings_buffer=8 opcache.max_accelerated_files=4000 \
		opcache.revalidate_freq=60 opcache.enable_cli=1 error_log=/run/blog/php-error.log "$@" $PHP_INI_EXTRA
}
# ext-protobuf: the RoadRunner worker packages use google/protobuf, whose README asks for it.
PROTOBUF=${PROTOBUF_SO:-$BUILD/src/protobuf-5.36.2/modules/protobuf.so}
# PDO prepares as the driver does by default: pdo_pgsql native, pdo_mysql emulated (PDO_EMULATE overrides).
emulate=${PDO_EMULATE:-$([ "$db" = pgsql ] && echo 0 || echo 1)}

run() { # name, docker args...
	local name=$1
	shift
	docker run -d --name "$name" --label blog-stack=1 --network host --cpuset-cpus "$STACK_CPUS" --memory "${STACK_MEMORY:-40g}" --ulimit nofile=1048576:1048576 "$@" >/dev/null
	echo -n "$name "
}

pg_dsn_bouncer='pgsql:host=127.0.0.1;port=6432;dbname=bench;user=postgres;password=bench'
pg_dsn="pgsql:host=${DBH};port=55440;dbname=bench;user=postgres;password=bench"
my_dsn="mysql:host=${DBH};port=53340;dbname=bench;user=root;password=bench;charset=utf8mb4"

# PgBouncer: $BOUNCERS processes on one port (so_reuseport), 24 server connections in total.
pgbouncer() {
	for n in $(seq 1 $BOUNCERS); do
		cat > "$RUN/pgbouncer-$n.ini" <<EOF
[databases]
bench = host=${DBH} port=55440 dbname=bench user=postgres password=bench
[pgbouncer]
listen_addr = 127.0.0.1
listen_port = 6432
so_reuseport = 1
unix_socket_dir =
auth_type = plain
auth_file = /run/blog/userlist.txt
pool_mode = transaction
default_pool_size = $(( 24 / BOUNCERS ))
max_client_conn = 2000
max_prepared_statements = 200
logfile = /run/blog/pgbouncer-$n.log
log_connections = 0
log_disconnections = 0
pidfile = /run/blog/pgbouncer-$n.pid
EOF
	done
	echo '"postgres" "bench"' > "$RUN/userlist.txt"
	run blog-pgbouncer -v "$RUN:/run/blog" -u "$(id -u)" "$IMG" sh -c \
		"for n in \$(seq 2 $BOUNCERS); do pgbouncer -d /run/blog/pgbouncer-\$n.ini; done; exec pgbouncer /run/blog/pgbouncer-1.ini"
}

case "$stack" in
fpm)
	if [ "$db" = pgsql ] && [ -n "$VIA_BOUNCER" ]; then
		pgbouncer
		dsn=$pg_dsn_bouncer persistent=1
	elif [ "$db" = pgsql ]; then
		dsn=$pg_dsn persistent=1
	else
		dsn=$my_dsn persistent=1
	fi
	php_ini "$PHP" > "$RUN/php.ini"
	upstream_line=
	[ -n "$UPSTREAM" ] && upstream_line="env[BLOG_UPSTREAM] = \"$UPSTREAM\""
	cat > "$RUN/php-fpm.conf" <<EOF
[global]
error_log = /run/blog/fpm.log
daemonize = no

[blog]
listen = 127.0.0.1:9000
listen.backlog = 4096
pm = static
pm.max_children = ${PHP_WORKERS:-$(( 4 * N ))}
clear_env = yes
env[BLOG_DSN] = "$dsn"
env[BLOG_PERSISTENT] = $persistent
env[BLOG_EMULATE_PREPARES] = $emulate
env[BLOG_DISABLE_PREPARES] = ${PDO_DISABLE_PREPARES:-0}
$upstream_line
EOF
	cat > "$RUN/nginx.conf" <<EOF
worker_processes $N;
events { worker_connections 8192; }
http {
	access_log off;
	keepalive_requests 1000000;
	server {
		listen ${LH}:8080 backlog=4096;
		location / {
			fastcgi_pass 127.0.0.1:9000;
			include fastcgi_params;
			fastcgi_param SCRIPT_FILENAME /app/fpm/app.php;
			fastcgi_param HTTP_AUTHORIZATION \$http_authorization;
		}
	}
}
EOF
	run blog-fpm -u "$(id -u)" -v "$PHP:$PHP:ro" -v "$IMPL/php:/app:ro" -v "$RUN:/run/blog" "$IMG" \
		"$PHP/sapi/fpm/php-fpm" -c /run/blog/php.ini -y /run/blog/php-fpm.conf
	run blog-nginx -v "$RUN/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:1.30.5
	port=8080
	;;
go)
	if [ "$db" = pgsql ]; then drv=pgx dsn="postgres://postgres:bench@${DBH}:55440/bench"; else drv=mysql dsn="root:bench@tcp(${DBH}:53340)/bench"; fi
	dsn=$dsn${DSN_SUFFIX:-}
	run blog-go -u "$(id -u)" -v "$IMPL/go:/go-blog:ro" -e "BLOG_UPSTREAM=${UPSTREAM:-}" -e BLOG_DRIVER=$drv -e "BLOG_DSN=$dsn" -e BLOG_POOL=$POOL -e BLOG_ADDR=${LH}:8081 \
		${GOENV:+-e $GOENV} "$IMG" /go-blog/blog
	port=8081
	;;
node-http | node-fastify)
	NODE=${NODE_HOME:-$HOME/.nvm/versions/node/v24.22.0}
	if [ "$db" = pgsql ]; then drv=pg dsn="postgres://postgres:bench@${DBH}:55440/bench"; else drv=mysql dsn="mysql://root:bench@${DBH}:53340/bench"; fi
	run blog-node -u "$(id -u)" -v "$NODE:/node:ro" -v "$IMPL/node:/app:ro" -e "BLOG_UPSTREAM=${UPSTREAM:-}" -e BLOG_SERVER=${stack#node-} -e BLOG_WORKERS=$N -e BLOG_DRIVER=$drv \
		-e "BLOG_DSN=$dsn" -e BLOG_POOL=$PER_PROC_POOL -e BLOG_ADDR=${LH}:8082 "$IMG" /node/bin/node /app/server.mjs
	port=8082
	;;
franken)
	ZTS=$(readlink -f "${PHP_ZTS_BUILD:-$BUILD/php85-zts}")
	FRANKEN=${FRANKENPHP:-$BUILD/src/frankenphp-1.13.1/frankenphp}
	dsn=$([ "$db" = pgsql ] && echo "$pg_dsn" || echo "$my_dsn")
	if [ "$db" = pgsql ] && [ -n "$VIA_BOUNCER" ]; then pgbouncer; dsn=$pg_dsn_bouncer; fi
	php_ini "$ZTS" > "$RUN/php.ini"
	cat > "$RUN/Caddyfile" <<EOF
{
	auto_https off
	admin off
	frankenphp {
		worker {
			file /app/frankenphp/worker.php
			num ${PHP_WORKERS:-$(( 2 * N ))}
			env BLOG_DSN "$dsn"
			env BLOG_STMT_CACHE "${STMT_CACHE:-0}"
			env BLOG_EMULATE_PREPARES "$emulate"
			env BLOG_UPSTREAM "${UPSTREAM:-}"
		}
	}
}
http://${LH}:8083 {
	bind ${LH}
	root * /app/frankenphp
	rewrite * /worker.php
	php
}
EOF
	run blog-franken -u "$(id -u)" -e GODEBUG=cgocheck=0 -e LD_LIBRARY_PATH=$ZTS/libs -v "$ZTS:$ZTS:ro" -v "$FRANKEN:/frankenphp:ro" -v "$IMPL/php:/app:ro" -v "$RUN:/run/blog" \
		-e PHPRC=/run/blog -e HOME=/run/blog -e XDG_DATA_HOME=/run/blog -e XDG_CONFIG_HOME=/run/blog "$IMG" /frankenphp run --config /run/blog/Caddyfile
	port=8083
	;;
rr)
	RR=${ROADRUNNER:-$BUILD/src/roadrunner-3.0.0/rr}
	dsn=$([ "$db" = pgsql ] && echo "$pg_dsn" || echo "$my_dsn")
	if [ "$db" = pgsql ] && [ -n "$VIA_BOUNCER" ]; then pgbouncer; dsn=$pg_dsn_bouncer; fi
	php_ini "$PHP" extension=/protobuf.so > "$RUN/php.ini"
	cat > "$RUN/rr.yaml" <<EOF
version: "3"
server:
  command: "$PHP/sapi/cli/php -c /run/blog/php.ini /app/roadrunner/worker.php"
  env:
    - BLOG_DSN: "$dsn"
    - BLOG_STMT_CACHE: "${STMT_CACHE:-0}"
    - BLOG_EMULATE_PREPARES: "$emulate"
    - BLOG_UPSTREAM: "${UPSTREAM:-}"
  relay: pipes
http:
  address: ${LH}:8084
  pool:
    num_workers: ${PHP_WORKERS:-$(( 2 * N ))}
    max_jobs: 0
logs:
  level: error
  output: /run/blog/rr.log
EOF
	run blog-rr -u "$(id -u)" -v "$PROTOBUF:/protobuf.so:ro" -v "$PHP:$PHP:ro" -v "$RR:/rr:ro" -v "$IMPL/php:/app:ro" -v "$RUN:/run/blog" -w /run/blog "$IMG" /rr serve -c /run/blog/rr.yaml
	port=8084
	;;
swoole)
	SWOOLE=${SWOOLE_SO:-$BUILD/src/swoole-src-6.2.3/modules/swoole.so}
	php_ini "$PHP" extension=/swoole.so > "$RUN/php.ini"
	dbport=$([ "$db" = pgsql ] && echo 55440 || echo 53340)
	run blog-swoole -u "$(id -u)" -v "$PHP:$PHP:ro" -v "$SWOOLE:/swoole.so:ro" -v "$IMPL/php:/app:ro" -v "$RUN:/run/blog" \
		-e "BLOG_UPSTREAM=${UPSTREAM:-}" -e BLOG_STMT_CACHE=${STMT_CACHE:-0} -e BLOG_EMULATE_PREPARES=$emulate -e BLOG_WORKERS=$N -e BLOG_POOL=${SWOOLE_POOL:-$PER_PROC_POOL} -e BLOG_DRIVER=$db -e BLOG_DB_HOST=$DBH -e BLOG_DB_PORT=$dbport -e BLOG_ADDR=${LH}:8085 "$IMG" "$PHP/sapi/cli/php" -c /run/blog/php.ini /app/swoole/server.php
	port=8085
	;;
python)
	PYAPP=${PY_BLOG_DIR:-$IMPL/python}
	if [ "$db" = pgsql ]; then drv=pg dsn="postgres://postgres:bench@${DBH}:55440/bench"; else drv=mysql dsn="mysql://root:bench@${DBH}:53340/bench"; fi
	# The venv and its uv-managed CPython live in $PYAPP; mounted at the same path, the venv's absolute symlinks resolve.
	run blog-python -u "$(id -u)" -v "$PYAPP:$PYAPP:ro" -e PYTHONDONTWRITEBYTECODE=1 -e "BLOG_UPSTREAM=${UPSTREAM:-}" -e BLOG_WORKERS=$N -e BLOG_DRIVER=$drv \
		-e "BLOG_DSN=$dsn" -e BLOG_POOL=$PER_PROC_POOL -e BLOG_ADDR=${LH}:8096 "$IMG" "$PYAPP/.venv/bin/python" "$PYAPP/server.py"
	port=8096
	;;
ruby)
	RUBY=${RUBY_HOME:-$HOME/.local/ruby-4.0.7}
	if [ "$db" = pgsql ]; then drv=pg dsn="postgres://postgres:bench@${DBH}:55440/bench"; else drv=mysql dsn="mysql://root:bench@${DBH}:53340/bench"; fi
	run blog-ruby -u "$(id -u)" -v "$RUBY:$RUBY:ro" -v "$IMPL/ruby:/app:ro" -w /app -e HOME=/tmp -e "BLOG_UPSTREAM=${UPSTREAM:-}" \
		-e BLOG_WORKERS=$N -e BLOG_THREADS=${RUBY_THREADS:-$PER_PROC_POOL} -e BLOG_POOL=$PER_PROC_POOL -e BLOG_DRIVER=$drv -e "BLOG_DSN=$dsn" -e BLOG_ADDR=${LH}:8098 \
		"$IMG" "$RUBY/bin/bundle" exec puma -C /app/puma.rb
	port=8098
	;;
rust)
	RUSTAPP=${RUST_BLOG_DIR:-$IMPL/rust}
	if [ "$db" = pgsql ]; then drv=pg dsn="postgres://postgres:bench@${DBH}:55440/bench"; else drv=mysql dsn="mysql://root:bench@${DBH}:53340/bench"; fi
	run blog-rust -u "$(id -u)" -v "$RUSTAPP/target/release:/rust-blog:ro" -e "BLOG_UPSTREAM=${UPSTREAM:-}" -e BLOG_DRIVER=$drv -e "BLOG_DSN=$dsn" -e BLOG_POOL=$POOL \
		-e BLOG_ADDR=${LH}:8097 "$IMG" /rust-blog/blog
	port=8097
	;;
java)
	JDK=${JAVA_HOME_BLOG:-$HOME/.local/jdk-25.0.4.1+1}
	if [ "$db" = pgsql ]; then drv=pg dsn="jdbc:postgresql://${DBH}:55440/bench?user=postgres&password=bench&sslmode=disable"
	else drv=mysql dsn="jdbc:mysql://${DBH}:53340/bench?user=root&password=bench&sslMode=DISABLED&allowPublicKeyRetrieval=true"; fi
	run blog-java -u "$(id -u)" -v "$JDK:/jdk:ro" -v "$IMPL/java/target/blog.jar:/blog.jar:ro" -e "BLOG_UPSTREAM=${UPSTREAM:-}" -e BLOG_DRIVER=$drv \
		-e "BLOG_DSN=$dsn" -e BLOG_POOL=$POOL -e BLOG_ADDR=${LH}:8099 "$IMG" /jdk/bin/java ${JAVA_OPTS:--XX:+UseG1GC -Xms64m -Xmx2g -XX:+ExitOnOutOfMemoryError} -jar /blog.jar
	port=8099
	;;
dotnet)
	DOTNET=${DOTNET_HOME:-$HOME/.dotnet}
	if [ "$db" = pgsql ]; then drv=pgsql dsn="Host=${DBH};Port=55440;Database=bench;Username=postgres;Password=bench"; else drv=mysql dsn="Server=${DBH};Port=53340;Database=bench;User ID=root;Password=bench;SslMode=None"; fi
	dsn=$dsn${DSN_SUFFIX:-}
	run blog-dotnet -u "$(id -u)" -v "$DOTNET:/dotnet:ro" -v "$IMPL/dotnet/out:/dotnet-blog:ro" -w /dotnet-blog -e "BLOG_UPSTREAM=${UPSTREAM:-}" -e BLOG_DRIVER=$drv -e "BLOG_DSN=$dsn" -e BLOG_POOL=$POOL \
		-e BLOG_ADDR=${LH}:8100 ${DOTNETENV:+-e $DOTNETENV} "$IMG" /dotnet/dotnet /dotnet-blog/Blog.dll
	port=8100
	;;
*)
	echo "unknown stack $stack" >&2
	exit 1
	;;
esac
echo
timeout 120 bash -c "until [ -n \"\$(docker ps -aq --filter label=blog-stack=1 --filter status=exited)\" ] && { docker ps -a --filter label=blog-stack=1 --filter status=exited --format '{{.Names}} exited' >&2; exit 1; } || code=\$(curl -s -o /dev/null -w '%{http_code}' http://$LH:$port/) && case \$code in 200|401|404) true ;; *) false ;; esac; do read -t 0.2 < /dev/zero || true; done"
