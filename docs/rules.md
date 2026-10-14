# Rules and configuration

Stage 1 measures every stack as its vendors ship it. Runtimes and servers run with their defaults plus the production setup their own documentation gives (php.ini-production and php.net's OPcache settings, `uvicorn[standard]`, the `dotnet new web` host, FrankenPHP's `GODEBUG` and build flags). Database drivers run with their defaults in every stack: no statement caches, prepare thresholds or session-reset switches beyond what the driver does on its own, even where its documentation offers them — those are a later, tuning stage, for all stacks at once. What the harness sets beyond that is sizing — process counts, pool sizes, heap limits, keep-alive, connection reuse — the same rule for every stack. Alternative libraries, allocators and JIT switches are also left to the tuning stage. All stack settings live in `harness/stack/up.sh`.

## Sizing (the same for every stack)
- Process counts with N = CPUs of the stack: PHP-FPM 4N children; FrankenPHP and RoadRunner workers 2N; Swoole, Node cluster and Python N processes; Ruby Puma N workers × ⌈24/N⌉ threads, one per database connection of the worker (Puma's MRI default is 5, which with 3 connections per worker leaves two threads waiting for one; 2 × ⌈C/N⌉ in the waiting series, because Puma spreads connections over its workers unevenly); Go, Rust, Java, .NET one process with all CPUs. In the waiting series every blocking model gets one PHP worker (FPM, FrankenPHP, RoadRunner) or about two Puma threads per concurrent request; RoadRunner's HTTP plugin refuses more than 500 workers ("number of workers can't be more than 500"), so its largest point is 500. That series is therefore a provisioning measurement (resources needed for C concurrent waiting requests without a queue), not a comparison of fixed production pools under rising load.
- Database pools: 24 connections per stack — Go, Rust, Java, .NET one pool of 24; Node, Swoole, Python, Ruby ⌈24/N⌉ per process; PHP workers that hold one connection each have one per worker. In the waiting series FPM, FrankenPHP and RoadRunner reach PostgreSQL through PgBouncer when they run more than 250 workers (transaction mode, N/2 processes, 24 server connections, `max_prepared_statements` 200), because 500–1000 workers do not fit into the server's 300 connections; otherwise every stack connects directly.
- Connections: the statements of a request share one connection taken from the pool, which goes back to the pool while the upstream is awaited. Each driver's default session reset runs when a connection goes back.
- Keep-alive to the upstream service in every stack (PHP: reused curl handles in the worker runtimes, `curl_share_init_persistent()` under FPM). With the default clients of some runtimes (Go's two idle connections per host, a new curl handle per request) every call would open a new TCP connection, and a few thousand calls per second exhaust the ephemeral ports.
- Listen backlog: Jetty's accept queue is set to 4096; its default (0) leaves the JVM's backlog of 50, against 511–4096 in the defaults of the other servers, and would drop connections when 5000 clients connect at once.
- Java heap: `-Xms64m -Xmx2g`. Without flags the JVM sizes the heap from the container limit (1/64 initial, 1/4 maximum), which here would measure the harness's 40 GB limit, not Java.
- No TLS between the stacks and the databases: PostgreSQL runs with `ssl=off`, and every MySQL driver is set to or defaults to plaintext (.NET: `SslMode=None`, since MySqlConnector's default `Preferred` uses TLS when the server offers it). Each run records the number of TLS sessions to MySQL.
- No per-request logging in any stack (nginx `access_log off`, RoadRunner `level: error`, .NET `System.Net.Http.HttpClient` at Warning).

## Departures from the defaults, and why
Beyond the sizing above, these settings differ from a default; each keeps the stacks doing the same work:
- Same SQL semantics: autocommit on for Python's asyncmy (its default is off, which would keep a transaction open across the statements of a request, unlike the other drivers); .NET sends string parameters to PostgreSQL untyped (`NpgsqlDbType.Unknown`), so the server infers their types (`char(64)`, `timestamp`) as it does for the parameters of pgx, node-postgres and PDO; by default Npgsql would send them as `text`.
- Same transport: keep-alive to the upstream in every stack, persistent PDO connections in FPM (the FPM processes are the connection pool), Jetty's accept queue of 4096.
- Runtime and server production setup from their own documentation: php.ini-production and php.net's OPcache settings, `uvicorn[standard]`, the `dotnet new web` host, FrankenPHP's `GODEBUG=cgocheck=0` and build flags.

## Database statements: the drivers' defaults
Each stack runs a parameterized statement with its driver's plain documented call; caching, preparation and protocol are whatever the driver does by default. What that means on the wire (4 statements per request; `harness/wire-check.sh`, output for this run in [results/2026-10/wire-check.txt](../results/2026-10/wire-check.txt) — the PostgreSQL log shows executes, not the Parse and Close messages, which follow from the drivers' code):

| stack | call | PostgreSQL | MySQL |
|---|---|---|---|
| PHP (FPM, FrankenPHP, RoadRunner, Swoole) | `PDO::prepare` + `execute` | native (pdo_pgsql default): prepare, execute and close for every statement | emulated (pdo_mysql default): one text query |
| Go | pgxpool / `database/sql` `QueryContext` | pgx caches prepared statements per connection | go-sql-driver: prepare, execute, close for every statement |
| Node | `client.query({text, values})` | unnamed statement: parsed every time | mysql2 `query()`: escaped on the client, one text query |
| Python | asyncpg `fetch` / asyncmy `execute` | asyncpg caches prepared statements per connection; the default session reset when a connection goes back to the pool (once per request, twice in the waiting series) | text query (no binary protocol in asyncmy) |
| Rust | tokio-postgres `query(&str)` / mysql_async `exec` | a statement prepared, executed and closed for every query | mysql_async caches statements, but the default reset when a connection goes back to the pool drops them: every statement prepared again |
| Ruby | pg `exec_params` / trilogy `query` | unnamed statement: parsed every time | text query (no binary protocol in trilogy) |
| Java | JDBC `PreparedStatement` | PgJDBC: server-side after 5 uses per connection (default `prepareThreshold`) | Connector/J: prepared on the client, one text query (default `useServerPrepStmts=false`) |
| .NET | ADO.NET `DbCommand` | Npgsql: unnamed statement; the default reset when a connection goes back to the pool | MySqlConnector: text query; the default reset when a connection goes back to the pool |

## PHP
- PHP 8.5.11 built from source with the extension set of the official `php:8.5` image plus sockets, pcntl, pdo_mysql, pdo_pgsql and the compiler and linker flags of that image (`-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64`, `-Wl,-O1 -pie`; `harness/stack/build-php.sh`).
- php.ini: the build's `php.ini-production` plus the OPcache settings php.net recommends (`memory_consumption=128`, `interned_strings_buffer=8`, `max_accelerated_files=4000`, `revalidate_freq=60`, `enable_cli=1`); JIT off (the default). JSON with `json_encode` defaults.
- nginx 1.30.5 `worker_processes N` (`auto` counts all host CPUs inside a container), FastCGI over TCP, persistent PDO connections in FPM (`PDO::ATTR_PERSISTENT`; not PDO's default, but without it every request opens a database connection, while the worker runtimes keep theirs — FPM processes are the pool).
- FrankenPHP 1.13.1 worker mode with `GODEBUG=cgocheck=0` (FrankenPHP performance docs); Swoole 6.2.3 with coroutine hooks and its curl support; RoadRunner 3.0.0 with `max_jobs: 0` and ext-protobuf (the google/protobuf package's README asks for it).

## Other runtimes
- Go 1.27.2: default GC, `encoding/json` defaults.
- Java 25 (Temurin): G1, heap as above; Jetty 12 with virtual threads (the stack's model); Jackson defaults apart from the snake_case names of the spec.
- .NET 10: the `dotnet new web` host (`WebApplication.CreateBuilder`), Server GC with DATAS, System.Text.Json with the minimal-API defaults apart from the snake_case names.
- Node 24.22.0: defaults.
- Python 3.14.8: `uvicorn[standard]` (uvloop and httptools, the installation uvicorn recommends), the `json` module.
- Ruby 4.0.7: YJIT off and glibc malloc (Ruby's defaults); Puma 8 defaults apart from the thread count (Sizing above).
- Rust 1.99.0: the default release profile.

## Harness
- Response check each time a stack is started: sha256 over status, media type and canonical JSON body (object keys sorted, escaping normalized) of the first 2000 requests of `spec/requests/requests.txt` (200 in the waiting series).
- Warm-up 3 s (equal numbers of clients), 15 s at each rate (fixed rates, rates in ascending order on one start of the stack), 30 s (waiting; JIT runtimes and fresh workers), 40 s with 500+ clients; a pause of wait + 1 s; measured 10 s (equal numbers of clients), 20 s (fixed rates), 30 s (0.1 s wait), 60 s (1 s wait).
- Rejected on connection errors, any 5xx, 404 or other unexpected status, a share of 401 outside a binomial tolerance, errors in the stack's logs.
- CPU per request = cgroup CPU seconds between snapshots right before and after wrk / requests completed; memory = anon + shmem + kernel of all the stack's containers at the peak of `memory.current`; busy cores of every CPU group of the host are recorded (`cpu_busy`), so load outside the stack's CPUs is visible.
