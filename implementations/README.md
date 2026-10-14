# Implementations

Every folder implements the same API ([spec](../spec/spec.md)) without a web framework or an ORM: the language's production HTTP server and its usual database drivers. The stack name (first column) is what the harness takes: `harness/stack/up.sh <stack> <pgsql|mysql>`.

| stack | folder | runtime | HTTP server, processes (N = CPUs of the stack) | PostgreSQL / MySQL driver | statements | JSON |
|---|---|---|---|---|---|---|
| `fpm` | [php](php) `fpm/app.php` | PHP 8.5.11 | nginx 1.30.5 + PHP-FPM, 4N children | PDO pgsql / PDO mysql, persistent | PDO defaults: native, not kept / emulated | `json_encode` |
| `franken` | [php](php) `frankenphp/worker.php` | PHP 8.5.11 ZTS | FrankenPHP 1.13.1 worker mode, 2N threads | PDO, one connection per worker | PDO defaults: native, not kept / emulated | `json_encode` |
| `rr` | [php](php) `roadrunner/worker.php` | PHP 8.5.11 | RoadRunner 3.0.0, 2N PHP worker processes | PDO, one connection per worker | PDO defaults: native, not kept / emulated | `json_encode` |
| `swoole` | [php](php) `swoole/server.php` | PHP 8.5.11 + Swoole 6.2.3 | Swoole HTTP server, N workers, a coroutine per request | Swoole `PDOPool`, ⌈24/N⌉ per worker | PDO defaults: native, not kept / emulated | `json_encode` |
| `go` | [go](go) | Go 1.27.2 | `net/http`, one process | pgxpool / `database/sql` + go-sql-driver, 24 | pgx cache / prepare per statement | `encoding/json` |
| `node-http`, `node-fastify` | [node](node) | Node 24.22.0 | `node:http` or Fastify 5.12.7, `cluster` with N processes | pg / mysql2, ⌈24/N⌉ per process | `query()`: unnamed / text | `JSON.stringify` |
| `rust` | [rust](rust) | Rust 1.99.0 | hyper 1.x on tokio, one process | tokio-postgres + deadpool / mysql_async, 24 | prepare per statement / cache dropped by reset | serde_json |
| `java` | [java](java) | Java 25 (Temurin) | Jetty 12 core handler on virtual threads, one process | PgJDBC / Connector/J, HikariCP 24 | PgJDBC default / HikariCP wiki settings | Jackson |
| `dotnet` | [dotnet](dotnet) | .NET 10 | Kestrel minimal APIs (`CreateBuilder`), one process | Npgsql / MySqlConnector, 24 | unnamed / text | System.Text.Json |
| `python` | [python](python) | CPython 3.14.8 | uvicorn + uvloop + httptools, N processes | asyncpg / asyncmy, ⌈24/N⌉ per process | asyncpg cache / text | `json` |
| `ruby` | [ruby](ruby) | Ruby 4.0.7 | Puma 8, N workers × 5 threads | pg / trilogy, ⌈24/N⌉ per worker | `exec_params`: unnamed / text | `json` |

Common contract (environment variables set by `harness/stack/up.sh`): `BLOG_DRIVER`, `BLOG_DSN`, `BLOG_POOL`, `BLOG_ADDR` (`host:port`), `BLOG_WORKERS` (multi-process servers), `BLOG_UPSTREAM` (optional URL every request calls after authentication; it must answer `{"ok":true}`). The PHP runtimes take their own subset (see [php](php/README.md)).

To change a stack, edit its folder; process counts, pool sizes and PHP settings are in `harness/stack/up.sh`. The rules every stack follows, and what each driver does on the wire, are in [docs/rules.md](../docs/rules.md).
