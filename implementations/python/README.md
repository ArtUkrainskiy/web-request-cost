# Blog API, Python "bare"

The task from `spec/spec.md` without a framework or ORM: a raw ASGI app (`app.py`) served by
uvicorn with uvloop and httptools in `BLOG_WORKERS` processes (`server.py`), asyncpg (PostgreSQL) or
asyncmy (MySQL) with a pool of `BLOG_POOL` connections per process, the `json` module for the body, aiohttp for the
optional upstream call (`BLOG_UPSTREAM`).

Versions (PyPI, 2026-10-13): CPython 3.14.8 (python-build-standalone via uv), uvicorn 0.54.0,
uvloop 0.23.0, httptools 0.9.0, asyncpg 0.32.0, asyncmy 0.2.16, aiohttp 3.14.5.
`requirements.in` holds the direct pins, `requirements.txt` the full lock with hashes.
CPython 3.15.0 is out, but asyncmy 0.2.16 has no cp315 wheel yet, so 3.14 is what a production
service would run today.

## Building the venv

The interpreter and the venv both live in this directory, so mounting the directory read-only
at the same absolute path in the container (`-v $PWD:$PWD:ro`, see the `python` case of
`harness/stack/up.sh`) is all the container needs: the venv's `bin/python` is an absolute symlink into
`.python/`, and python-build-standalone runs on the plain `blog-runtime` Ubuntu image.

```sh
cd implementations/python
export UV_PYTHON_INSTALL_DIR=$PWD/.python            # uv-managed CPython inside the app dir
uv python install --no-bin 3.14.8                    # --no-bin: no python3.14 link in ~/.local/bin
uv venv --managed-python --python 3.14.8 .venv
uv pip sync --python .venv/bin/python --require-hashes --compile-bytecode requirements.txt
.venv/bin/python -m compileall -q app.py server.py   # the mount is read-only: compile once here
```

uv 0.13.0 was used (a static binary from https://github.com/astral-sh/uv/releases). To change a pin,
edit `requirements.in` and relock:
`uv pip compile --python-version 3.14 --python-platform x86_64-manylinux_2_28 --generate-hashes requirements.in -o requirements.txt`.

On another machine the directory must sit at a path that the same `up.sh` case mounts; if the
path changes, rebuild `.venv` (its symlinks are absolute). `.python/` and `.venv/` are build output.

## Running

```sh
BLOG_WORKERS=8 BLOG_DRIVER=pg BLOG_DSN=postgres://postgres:bench@127.0.0.1:55440/bench BLOG_POOL=3 \
	BLOG_ADDR=127.0.0.1:8096 .venv/bin/python server.py
BLOG_WORKERS=8 BLOG_DRIVER=mysql BLOG_DSN=mysql://root:bench@127.0.0.1:53340/bench BLOG_POOL=3 \
	BLOG_ADDR=127.0.0.1:8096 .venv/bin/python server.py
```

## Choices

- Processes: uvicorn's own supervisor (`workers=N`) — one parent, N spawned workers sharing the listening
  socket, plus the `multiprocessing` resource tracker (one small extra process). Same shape as Node's
  cluster. The event loop is uvloop and the HTTP parser httptools in every worker.
- Pool: ⌈24/N⌉ connections per process, as Node and Swoole; opened on demand (`min_size=0`), as `pg.Pool`
  and pgxpool. The statements of a request share one connection (`pool.acquire()`), returned to the pool
  while the upstream is awaited; asyncpg's default reset runs when it goes back.
- asyncpg prepares every statement on the server and caches it per connection (driver default, 100
  statements), as pgx does. asyncmy (maintained, release 2026-10; aiomysql's last release is 2025-10)
  speaks only the text protocol and interpolates parameters on the client — there is no async MySQL
  driver for Python with the binary protocol. `autocommit=True` as the other drivers (asyncmy defaults to off, which would keep a
  REPEATABLE READ snapshot open on every pooled connection).
- JSON: the standard `json` module with its defaults (`json.dumps`: non-ASCII escaped, `", "` and `": "`
  separators). orjson would be a tuning step.
- Upstream: one `aiohttp.ClientSession` per process with an unlimited keep-alive connector (like
  Node's keep-alive agent and Go's transport, both without a connection limit). aiohttp rather than httpx:
  it is the faster and more widely deployed async client; httpx is slower under concurrency.
- Responses: `Content-Type: application/json` and `Content-Length`; uvicorn adds `date`, the
  `server` header is off.
