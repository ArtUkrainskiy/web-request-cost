#!/bin/bash
# Removes every stack container started by up.sh.
ids=$(docker ps -aq --filter label=blog-stack=1)
[ -n "$ids" ] && docker rm -f $ids >/dev/null
exit 0
