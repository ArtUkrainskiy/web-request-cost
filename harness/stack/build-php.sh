#!/bin/bash
# Builds the two PHP 8.5.11 variants the stacks use into .build/ of the repository, with the extension
# set and compiler flags of the official php:8.5 image (its default extensions plus mbstring, mysqlnd, argon2, sodium,
# sqlite, curl, iconv, openssl, readline, zlib), sockets, pcntl, pdo_mysql and pdo_pgsql:
#   .build/php85-fpm  NTS, PHP-FPM and CLI (FPM, RoadRunner workers, Swoole)
#   .build/php85-zts  ZTS, embed, no Zend signals, Zend max execution timers (FrankenPHP; the flags its docs require)
#   PHP_SRC=<php-src checkout at php-8.5.11, or an unpacked php-8.5.11 tarball> ./build-php.sh
# Each variant is built in a copy of the sources (the stacks run the binaries from the build tree).
set -e
: "${PHP_SRC:?set PHP_SRC}"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${BUILD_DIR:-$ROOT/.build}
EXT="--enable-ctype --enable-tokenizer --enable-filter --enable-session --enable-posix --enable-fileinfo --enable-phar
--with-libxml --enable-dom --enable-xml --enable-simplexml --enable-xmlreader --enable-xmlwriter
--enable-mbstring --enable-mysqlnd --with-password-argon2 --with-sodium --with-curl --with-iconv --with-openssl
--with-readline --with-zlib --enable-ftp --enable-sockets --enable-pcntl --enable-pdo --with-pdo-sqlite --with-sqlite3 --with-pdo-mysql --with-pdo-pgsql"
# Compiler flags of the official php:8.5 Docker images (docker-library/php, 8.5/*/Dockerfile).
PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64"
PHP_LDFLAGS="-Wl,-O1 -pie"
mkdir -p "$OUT"
build() { # name, extra configure flags
	local dir=$OUT/$1
	rm -rf "$dir"
	cp -a "$PHP_SRC" "$dir"
	(cd "$dir" && { [ -x configure ] || ./buildconf --force >/dev/null; } &&
		./configure --disable-all --disable-cgi --disable-phpdbg --enable-cli $EXT $2 \
			CFLAGS="$PHP_CFLAGS" CPPFLAGS="$PHP_CFLAGS" LDFLAGS="$PHP_LDFLAGS" >/dev/null &&
		nice -n 10 make -s -j"$(nproc)" >/dev/null)
	echo "$1: $("$dir/sapi/cli/php" -n -v | head -1)"
}
build php85-fpm "--enable-fpm"
build php85-zts "--enable-zts --enable-embed --disable-zend-signals --enable-zend-max-execution-timers"
"$OUT/php85-fpm/sapi/cli/php" -n -m | tr '\n' ' '
echo
