#!/bin/bash
# Creates the two database containers on the host network and loads the blog data.
#   DB_CPUS=0-7,16-23 ./db.sh create <blog-pg.sql.gz> <blog-my.sql.gz>
#   ./db.sh check <min connections>     prints the settings the run records; fails if too low
# PostgreSQL 17 on :55440, MySQL 8.4 on :53340 (DB_LISTEN, default 127.0.0.1), both max_connections=300.
set -e
PGPORT=55440
MYPORT=53340

case "$1" in
create)
	: "${DB_CPUS:?set DB_CPUS}"
	docker rm -f blog-pg blog-mysql >/dev/null 2>&1 || true
	docker run -d --name blog-pg --network host --cpuset-cpus "$DB_CPUS" -e POSTGRES_PASSWORD=bench -e POSTGRES_DB=bench \
		postgres:17.11 -c port=$PGPORT -c listen_addresses=${DB_LISTEN:-127.0.0.1} -c max_connections=300 >/dev/null
	docker run -d --name blog-mysql --network host --cpuset-cpus "$DB_CPUS" -e MYSQL_ROOT_PASSWORD=bench -e MYSQL_DATABASE=bench \
		mysql:8.4.11 --port=$MYPORT --bind-address=${DB_LISTEN:-127.0.0.1} --max-connections=300 --mysqlx=OFF >/dev/null
	timeout 120 bash -c "until docker exec blog-pg pg_isready -q -h 127.0.0.1 -p $PGPORT -U postgres 2>/dev/null; do read -t 1 < /dev/zero || true; done"
	timeout 180 bash -c "until docker exec blog-mysql mysql -h127.0.0.1 -P$MYPORT -uroot -pbench -e 'SELECT 1' >/dev/null 2>&1; do read -t 1 < /dev/zero || true; done"
	gunzip -c "$2" | docker exec -i blog-pg psql -q -h 127.0.0.1 -p $PGPORT -U postgres -d bench >/dev/null
	docker exec blog-pg psql -q -h 127.0.0.1 -p $PGPORT -U postgres -d bench -c 'ANALYZE' >/dev/null
	gunzip -c "$3" | docker exec -i blog-mysql mysql -h127.0.0.1 -P$MYPORT -uroot -pbench bench 2>/dev/null
	docker exec blog-mysql mysql -h127.0.0.1 -P$MYPORT -uroot -pbench bench -e 'ANALYZE TABLE symfony_demo_post, symfony_demo_comment, symfony_demo_user, symfony_demo_post_tag, blog_session' >/dev/null 2>&1
	"$0" check 0
	;;
check)
	min=${2:-0}
	pg=$(docker exec blog-pg psql -h 127.0.0.1 -p $PGPORT -U postgres -d bench -Atc "SELECT split_part(current_setting('server_version'), ' ', 1), current_setting('max_connections'), current_setting('plan_cache_mode'), current_setting('shared_buffers'), (SELECT COUNT(*) FROM symfony_demo_post), (SELECT COUNT(*) FROM blog_session)" | tr '|' ' ')
	my=$(docker exec blog-mysql mysql -h127.0.0.1 -P$MYPORT -uroot -pbench bench -Nse "SELECT @@version, @@max_connections, @@innodb_buffer_pool_size, (SELECT COUNT(*) FROM symfony_demo_post), (SELECT COUNT(*) FROM blog_session)" 2>/dev/null | tr '\t' ' ')
	read -r pgv pgmax pgplan pgsb pgposts pgsess <<<"$pg"
	read -r myv mymax mybp myposts mysess <<<"$my"
	echo "{\"pg\":{\"version\":\"$pgv\",\"max_connections\":$pgmax,\"plan_cache_mode\":\"$pgplan\",\"shared_buffers\":\"$pgsb\",\"posts\":$pgposts,\"sessions\":$pgsess},\"mysql\":{\"version\":\"$myv\",\"max_connections\":$mymax,\"innodb_buffer_pool_size\":$mybp,\"posts\":$myposts,\"sessions\":$mysess},\"db_cpus\":\"$(docker inspect -f '{{.HostConfig.CpusetCpus}}' blog-pg)\"}"
	[ "$pgmax" -ge "$min" ] && [ "$mymax" -ge "$min" ] && [ "$pgposts" = 3000 ] && [ "$myposts" = 3000 ] && [ "$pgsess" = 1000 ] && [ "$mysess" = 1000 ]
	;;
esac
