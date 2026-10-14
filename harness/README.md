# Harness

Runs every stack in Docker containers on the host network, pinned to fixed CPU sets, loads it with wrk and samples the cgroups of the stack's and the databases' containers.

## Setup (once)
Run everything from this folder (`harness/`). The published results come from Ubuntu 26.04 on a 16-core / 32-thread AMD Ryzen 9 5950X; the scripts expect Ubuntu 24.04 or newer on x86-64 with Docker, cgroup v2, wrk 4.x, wrk2, Node 24 (for the response check), Python 3 and Go 1.27.
```sh
sudo apt install build-essential autoconf bison re2c pkg-config libxml2-dev libsqlite3-dev libssl-dev \
  zlib1g-dev libcurl4-openssl-dev libonig-dev libpq-dev libreadline-dev libargon2-dev libsodium-dev git curl wrk
docker build --build-arg UBUNTU=$(. /etc/os-release; echo $VERSION_ID) -t blog-runtime:$(. /etc/os-release; echo $VERSION_ID) -f stack/Dockerfile.runtime stack
DB_CPUS=0-5,16-21 stack/db.sh create ../spec/data/blog-pg.sql.gz ../spec/data/blog-my.sql.gz   # PostgreSQL 17 on :55440, MySQL 8.4 on :53340
(cd upstream && go build -o upstream .)                                                       # stub for the waiting scenario
git clone --depth 1 --branch php-8.5.11 https://github.com/php/php-src.git /tmp/php-src
PHP_SRC=/tmp/php-src stack/build-php.sh && stack/build-extras.sh                              # PHP, FrankenPHP, Swoole, RoadRunner into ../.build
# wrk2 (fixed request rate) at commit 44a94c1; its bundled LuaJIT writes a broken bytecode object for current
# binutils, so the bytecode is regenerated as C and the binary relinked
git clone https://github.com/giltene/wrk2.git /tmp/wrk2 && cd /tmp/wrk2 && git checkout 44a94c17d8e6a0bac8559b53da76848e430cb7a7 && make
LUA_PATH="deps/luajit/src/?.lua;;" deps/luajit/src/luajit -b src/wrk.lua obj/bytecode.c && gcc -c obj/bytecode.c -o obj/bytecode.o
rm wrk && make && cp wrk ~/.local/bin/wrk2 && cd -                                             # run.sh calls wrk2 (WRK2 overrides the path)
```
Then build each implementation as its README says (`go build`, `npm ci`, `cargo build --release`, …). Java, .NET, Ruby and Node runtimes are mounted into the containers from `JAVA_HOME_BLOG`, `DOTNET_HOME`, `RUBY_HOME`, `NODE_HOME` (see `stack/up.sh` for the defaults).

Notes:
- The CPU sets in the examples split a 32-thread host into groups that do not share physical cores: databases `0-5,16-21`, load generator `6-7,22-23`, stack `8-11,24-27`, upstream stub `12-15,28-31`. On another host pick sets the same way (`lscpu -e` shows which threads share a core).
- `stack/db.sh create` removes existing containers named `blog-pg` and `blog-mysql`. It uses the images `postgres:17.11` and `mysql:8.4.11`; the versions are also recorded in every result line (`dbinfo` field).
- `--memory` (`STACK_MEMORY`, default 40 GB) limits each container separately, not the stack as a whole; it is a guard, not a memory budget, and no series came near it.
- `stack/up.sh` writes configuration into `RUN_DIR` (default `/tmp/blog-stack`); two harnesses on one host need different `RUN_DIR`s and ports.

## Scripts
| script | what it does |
|---|---|
| `stack/up.sh <stack> <pgsql\|mysql>` | starts one stack on `$STACK_CPUS`, waits until it answers, prints its container names; all settings of every stack are here |
| `stack/down.sh` | removes the stack's containers |
| `stack/db.sh create\|check` | creates and loads the two database containers; `check` prints the settings a run records and fails if `max_connections` is too low |
| `stack/upstream.sh start\|stop` | starts the upstream stub (`upstream/`) on `$UPSTREAM_CPUS`, port 9090 |
| `wire-check.sh` | starts each stack on both databases and counts what its driver sends for 10 requests (PostgreSQL statement log, MySQL `Com_*` counters); no load |
| `verify-all.sh` | starts each stack on both databases and checks its responses against the reference hash; no load |
| `run.sh <stack> <db> <C>` | one measured run: database check, warm-up, pause, wrk with C connections while sampling cgroups; appends one JSON line to `$OUT` or rejects the run |
| `sweep.sh <stack> <db> "<C list>"` | starts a stack once, checks its responses, runs `run.sh` for each C |
| `matrix.sh` | the "memory" series: every stack × database, `REPS` passes in shuffled order |
| `wait.sh` | the "waiting" series: every request also calls the upstream stub that answers after 100 ms or 1 s; blocking models are provisioned with a worker or thread per client |
| `load/verify.mjs` | response check (sha256 over status, media type and canonical JSON) |
| `load/wrk.lua` | replays `spec/requests/requests-zipf.txt`; counts statuses and body bytes |
| `load/sample.py`, `load/cgcpu.py`, `load/cpustat.py`, `load/netseg.py` | cgroup sampler (memory), cgroup CPU snapshots around wrk, per-CPU-group host load, TCP segments per connection class (`PROBES=1`) |

Example (the settings of the series in `results/`):
```sh
STACK_CPUS=8-11,24-27 LOAD_CPUS=6-7,22-23 ./verify-all.sh
SERIES=memory REPS=3 STACK_CPUS=8-11,24-27 LOAD_CPUS=6-7,22-23 CONC="1 10 50 200" ./matrix.sh
SERIES=rate REPS=3 STACK_CPUS=8-11,24-27 LOAD_CPUS=6-7,22-23 CONC=50 RATES="1000 2000 4000" WARMUP=15 DURATION=20 ./matrix.sh
STACK_CPUS=8-11,24-27 LOAD_CPUS=6-7,22-23 UPSTREAM_CPUS=12-15,28-31 SERIES=wait100 WAITS=100 CONC_BLOCKING=100 CONC_RR=100 CONC_ASYNC=100 ./wait.sh
STACK_CPUS=8-11,24-27 LOAD_CPUS=6-7,22-23 UPSTREAM_CPUS=12-15,28-31 SERIES=wait1000 WAITS=1000 ./wait.sh
# PHP-FPM statement variants (PostgreSQL, C=50)
STACK_CPUS=8-11,24-27 LOAD_CPUS=6-7,22-23 STACKS=fpm DBS=pgsql REPS=3 CONC=50 PDO_EMULATE=1 SERIES=variant-fpm-emulated ./matrix.sh
STACK_CPUS=8-11,24-27 LOAD_CPUS=6-7,22-23 STACKS=fpm DBS=pgsql REPS=3 CONC=50 PDO_DISABLE_PREPARES=1 SERIES=variant-fpm-noprep ./matrix.sh
STACK_CPUS=8-11,24-27 LOAD_CPUS=6-7,22-23 STACKS=fpm DBS=pgsql REPS=3 CONC=50 VIA_BOUNCER=1 SERIES=variant-fpm-pgbouncer ./matrix.sh
# what each driver sends to the databases (results/2026-10/wire-check.txt)
STACK_CPUS=8-11,24-27 ./wire-check.sh
```

Options of `run.sh` beyond the examples:
- `PROBES=1` adds diagnostics to each record: TCP segments and bytes of the stack's connections to the databases (`net`, from `ss -ti`), user/system CPU and context switches per cgroup in `cpu_window`, and the user/system/softirq/steal breakdown of each CPU group in `cpu_busy`.
- Variant runs (not set in the published series apart from `PHP_WORKERS` in the waiting series; each is written to the record — `env`, `PHP_WORKERS` to `php_workers`): `POOL` — database connections per stack instead of 24; `SWOOLE_POOL` — Swoole connections per worker; `PHP_WORKERS` — FPM, FrankenPHP and RoadRunner worker count; `PHP_INI_EXTRA` — space-separated php.ini lines appended for every PHP stack (for example `mysqlnd.collect_statistics=0`); `DSN_SUFFIX` — appended to the Go and .NET connection strings (for example `?interpolateParams=true`, `;Max Auto Prepare=20`); `PHP_ZTS_BUILD` — another ZTS build directory for FrankenPHP.
- The stack, the databases and the load generator can run on separate hosts: `DB_HOST` (address of the databases for the stacks), `LISTEN_HOST` (address the stack listens on), `STACK_HOST` (the stack's address for the load generator), `LOAD_SSH` and `DB_SSH` (ssh destinations where wrk, the response check and the upstream stub, and the database checks and CPU snapshots run; the repository at the same path there), `LOAD_NODE` (Node on the load host), `UPSTREAM_HOST`; `stack/db.sh` takes `DB_LISTEN`.
Results go to `results/<series>-<date>.jsonl` in this folder (one record per run: wrk summary with status counts, cgroup samples, CPU-group load, settings).

## Response check
`load/verify.mjs` hashes `<status> <media type> <canonical JSON>` over the first N lines of `spec/requests/requests.txt`. Canonical: keys sorted, so the order of keys and the escaping of `/` and non-ASCII do not count. Reference hashes:

| hash | where | requests |
|---|---|---|
| `4cb01d08…` | `verify-all.sh`, `sweep.sh`, `run.sh` (equal-clients and fixed-rate series) | first 2,000, canonical |
| `75cf4840…` | `wait.sh` | first 200, canonical (with a wait, 2,000 take minutes) |

## Measurement
- Memory series: warm-up 3 s, measured window 10 s. Waiting series: warm-up 30 s (40 s with 500+ clients), window 30 s (0.1 s wait) or 60 s (1 s wait). After the warm-up, a pause of wait + 1 s so the warm-up's requests finish.
- CPU per request = cgroup CPU seconds of the stack's containers between snapshots taken right before and right after wrk (`cpu_window`, `load/cgcpu.py`) / requests wrk completed. Memory = anon + shmem + kernel of all the stack's containers at the peak of `memory.current` (sampled every 200 ms).
- A run is rejected on connection errors, any 5xx, 404 or other unexpected status (every page and post in the request lists exists), a 401 share outside its binomial tolerance, or errors in the stack's logs.
- Each record also keeps the effective configuration (`config`: command, environment and image ID of every container, and the configuration files `up.sh` wrote) and the number of TLS sessions to MySQL (`db_tls_sessions`; PostgreSQL runs with `ssl=off`).
