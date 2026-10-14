# PHP

`blog.php` holds the API logic shared by every PHP runtime: `blog_handle()` takes a PDO connection (or acquire/release closures of a pool), the path, the query and the `Authorization` header, and returns `[status, JSON body]`. Each runtime has a thin entry point:

| folder | runtime | entry point |
|---|---|---|
| `fpm/` | PHP-FPM behind nginx | `app.php` — one request per process run, persistent PDO |
| `frankenphp/` | FrankenPHP worker mode | `worker.php` — `frankenphp_handle_request()` loop, one PDO per worker |
| `roadrunner/` | RoadRunner | `worker.php` — PSR-7 worker (`roadrunner/http`, `composer.lock`), one PDO per worker |
| `swoole/` | Swoole HTTP server | `server.php` — N workers, a coroutine per request, `PDOPool` |

Environment of FPM, FrankenPHP and RoadRunner: `BLOG_DSN` (PDO DSN), `BLOG_PERSISTENT` (FPM), `BLOG_STMT_CACHE` (1: keep PDO statements per connection in the worker runtimes; off by default), `BLOG_EMULATE_PREPARES` (1: PDO emulated prepares; the stack passes the driver default — native on PostgreSQL, emulated on MySQL), `BLOG_DISABLE_PREPARES` (1: `Pdo\Pgsql::ATTR_DISABLE_PREPARES` on PostgreSQL), `BLOG_UPSTREAM`. Swoole builds its `PDOPool` from `BLOG_DRIVER` (`pgsql` or `mysql`), `BLOG_DB_PORT` and `BLOG_POOL` (connections per worker), and takes `BLOG_ADDR`, `BLOG_WORKERS` and `BLOG_UPSTREAM`.

## Build
PHP 8.5.11 and the runtimes are built by the harness into `.build/` of the repository:
```sh
PHP_SRC=<php-src at tag php-8.5.11> harness/stack/build-php.sh   # .build/php85-fpm (NTS + FPM), .build/php85-zts (ZTS + embed)
harness/stack/build-extras.sh                                   # FrankenPHP, Swoole, ext-protobuf, RoadRunner, roadrunner/vendor
```
PHP settings (php.ini, FPM pool, Caddyfile, rr.yaml) are written by `harness/stack/up.sh` at start.
