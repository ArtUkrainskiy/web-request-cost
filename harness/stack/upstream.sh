#!/bin/bash
# Starts or stops the upstream stand-in (go/upstream) on 127.0.0.1:9090, on $UPSTREAM_CPUS.
#   UPSTREAM_CPUS=12-15,28-31 ./upstream.sh start | stop
set -e
DIR=$(cd "$(dirname "$0")/.." && pwd)
UBUNTU=$(. /etc/os-release && echo "$VERSION_ID")
docker rm -f blog-upstream >/dev/null 2>&1 || true
export UPSTREAM_LISTEN=${UPSTREAM_LISTEN:-127.0.0.1}
if [ "$1" = start ]; then
	: "${UPSTREAM_CPUS:?set UPSTREAM_CPUS}"
	docker run -d --name blog-upstream --network host --cpuset-cpus "$UPSTREAM_CPUS" --ulimit nofile=1048576:1048576 \
		-v "$DIR/upstream:/up:ro" -e UPSTREAM_ADDR=${UPSTREAM_LISTEN:-127.0.0.1}:9090 "blog-runtime:$UBUNTU" /up/upstream >/dev/null
	timeout 10 bash -c 'until curl -s -o /dev/null "http://${UPSTREAM_LISTEN:-127.0.0.1}:9090/wait?ms=0"; do read -t 0.1 < /dev/zero || true; done'
fi
