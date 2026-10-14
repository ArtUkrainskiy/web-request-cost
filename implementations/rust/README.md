# Blog API — bare Rust (hyper + tokio-postgres / mysql_async)

The task is in `spec/spec.md`; this is the Rust counterpart of `implementations/go` (net/http + pgx):
no web framework, no ORM, one process, a pool of `BLOG_POOL` (24) connections; the statements of a
request share one connection, released while the upstream is awaited.

- HTTP: hyper 1.x `server::conn::http1` + hyper-util, multi-threaded tokio runtime (worker threads =
  available CPUs, which respects the container's cpuset, like GOMAXPROCS).
- PostgreSQL: tokio-postgres + deadpool-postgres (`RecyclingMethod::Fast`), statements through
  `client.query(&str, …)`: tokio-postgres prepares and executes every statement (no cache by default).
- MySQL: mysql_async with its default per-connection statement cache (32), pool `PoolConstraints(24, 24)`,
  default `reset_connection` (the session is reset on every return to the pool, which also drops the statement cache,
  so each statement is prepared again after a checkout).
- Upstream (`BLOG_UPSTREAM`): hyper-util legacy client (keep-alive pool), body must be `{"ok":true}`.

Build (Rust 1.99.0, the stable toolchain at the time of the run):

    curl --proto '=https' -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.99.0
    cargo build --release --locked

Run:

    BLOG_DRIVER=pg    BLOG_DSN=postgres://postgres:bench@127.0.0.1:55440/bench BLOG_POOL=24 BLOG_ADDR=127.0.0.1:8097 target/release/blog
    BLOG_DRIVER=mysql BLOG_DSN=mysql://root:bench@127.0.0.1:53340/bench         BLOG_POOL=24 BLOG_ADDR=127.0.0.1:8097 target/release/blog

The binary links glibc and libz (mysql_async's default `flate2/zlib`) and runs in the `blog-runtime` image of the host (`harness/stack/Dockerfile.runtime`).
