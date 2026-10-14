#!/bin/bash
# Builds FrankenPHP 1.13.1, Swoole 6.2.3 and ext-protobuf 5.36.2 against the PHP builds of build-php.sh,
# and fetches RoadRunner 3.0.0 and the RoadRunner worker's Composer packages. Run after build-php.sh.
#   [GO=<dir with go 1.27>] [COMPOSER_PHP=<php for composer>] ./build-extras.sh
# Everything goes to .build/ of the repository (sources under .build/src).
set -e
DIR=$(cd "$(dirname "$0")/.." && pwd)
BUILDS=${BUILD_DIR:-$(cd "$DIR/.." && pwd)/.build}
SRC=$BUILDS/src
GO=${GO:-$(dirname "$(command -v go)")}
COMPOSER_PHP=${COMPOSER_PHP:-$BUILDS/php85-fpm/sapi/cli/php}
mkdir -p "$SRC"
cd "$SRC"

# FrankenPHP: links libphp.so of the ZTS build (needs --enable-embed --disable-zend-signals); C flags as in
# FrankenPHP's official Dockerfile (-DFRANKENPHP_VERSION plus the PHP image's CFLAGS, see build-php.sh).
test -d frankenphp-1.13.1 || git clone -q --depth 1 --branch v1.13.1 https://github.com/php/frankenphp.git frankenphp-1.13.1
B=$BUILDS/php85-zts
LIBS=$(sh "$B/scripts/php-config" --libs)
(cd frankenphp-1.13.1/caddy/frankenphp && PATH=$GO:$PATH GOTOOLCHAIN=local CGO_ENABLED=1 \
	CGO_CFLAGS="-DFRANKENPHP_VERSION=1.13.1 -fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64 -I$B -I$B/main -I$B/Zend -I$B/TSRM -I$B/ext -I$B/ext/date/lib" \
	CGO_LDFLAGS="-L$B/libs -lphp $LIBS -Wl,-rpath,$B/libs" \
	go build -tags=nobadger,nomysql,nopgx,nowatcher,nomercure,novulcain -o "$SRC/frankenphp-1.13.1/frankenphp" .)

# Swoole: phpize needs installed headers, so the NTS build is installed into a staging prefix
F=$BUILDS/php85-fpm
I=$F/_inst
rm -rf "$I"
(cd "$F" && make -s install INSTALL_ROOT="$I" >/dev/null)
sed -i "s|^prefix=\"/usr/local\"|prefix=\"$I/usr/local\"|; s|^prefix='/usr/local'|prefix='$I/usr/local'|" "$I/usr/local/bin/php-config" "$I/usr/local/bin/phpize"
test -d swoole-src-6.2.3 || git clone -q --depth 1 --branch v6.2.3 https://github.com/swoole/swoole-src.git swoole-src-6.2.3
(cd swoole-src-6.2.3 && "$I/usr/local/bin/phpize" >/dev/null && \
	./configure --with-php-config="$I/usr/local/bin/php-config" --enable-mysqlnd --enable-swoole-pgsql --enable-swoole-curl >/dev/null && \
	make -s -j"$(nproc)" >/dev/null)

# ext-protobuf for the RoadRunner workers (the google/protobuf package's README: without it,
# performance will be lower); version matches google/protobuf in the composer.lock files
test -d protobuf-5.36.2 || curl -fsSL https://pecl.php.net/get/protobuf-5.36.2.tgz | tar -xz
(cd protobuf-5.36.2 && "$I/usr/local/bin/phpize" >/dev/null && ./configure --with-php-config="$I/usr/local/bin/php-config" >/dev/null && \
	make -s -j"$(nproc)" >/dev/null)

# RoadRunner binary and the worker's packages (composer.lock in implementations/php/roadrunner)
mkdir -p roadrunner-3.0.0
test -x roadrunner-3.0.0/rr || (curl -fsSL https://github.com/roadrunner-server/roadrunner/releases/download/v3.0.0/roadrunner-3.0.0-linux-amd64.tar.gz \
	| tar -xz -C roadrunner-3.0.0 --strip-components=1 roadrunner-3.0.0-linux-amd64/rr)
test -f composer.phar || curl -fsSL -o composer.phar https://getcomposer.org/download/latest-stable/composer.phar
(cd "$DIR/../implementations/php/roadrunner" && "${COMPOSER_PHP:?php with phar for composer}" "$SRC/composer.phar" install --no-interaction --no-dev)
echo "frankenphp: $("$SRC/frankenphp-1.13.1/frankenphp" version | head -1)"
echo "swoole: $("$F/sapi/cli/php" -n -d extension="$SRC/swoole-src-6.2.3/modules/swoole.so" -r 'echo swoole_version();')"
echo "roadrunner: $("$SRC/roadrunner-3.0.0/rr" --version)"
echo "protobuf: $("$F/sapi/cli/php" -n -d extension="$SRC/protobuf-5.36.2/modules/protobuf.so" -r 'echo phpversion("protobuf");')"
