# web-request-cost

How much CPU, memory and money one web request costs on 12 server stacks in 8 languages — the same JSON API without application frameworks (on plain HTTP servers and, for Node, also Fastify) in PHP, Go, Node, Rust, Java, .NET, Python and Ruby, every stack on its vendors' defaults, measured on one machine with the same database access rules and checked responses.

**Status: stage 1, bare runtimes with their defaults** — every stack as its vendors ship it, with the production setup their documentation gives for the runtime and server and the database drivers on their defaults; tuning is a later stage. Frameworks (Laravel, Symfony, NestJS, Spring, ASP.NET MVC, FastAPI, axum, Rails, …) are the next stage. Stage 1 is the baseline: vendor defaults under equal rules; later stages change one thing at a time against it (driver settings, tuning, frameworks, cloud).

**In one paragraph.** At the same load of 2000 req/s on PostgreSQL the stacks spend 0.27–0.51 ms of CPU per request (.NET 0.83 ms, most of it its thread pool spinning while idle), and the database spends 0.52–1.50 ms per request on top of that. Which of the two dominates depends mostly on the database driver's default: drivers that keep prepared statements on each connection (Java's PgJDBC, Go's pgx, Python's asyncpg) cost PostgreSQL 34–47% of what the others do. The PHP models with a worker process per waiting request (FPM, FrankenPHP, RoadRunner) need 1–11.5 GiB per 1000 requests that wait on another service, the other stacks 0.02–0.9 GiB. This compares execution models and driver defaults more than languages. The numbers come from one desktop machine over loopback; the dollars are a model, not a bill.

## Results
Stack on 4 cores / 8 threads of an AMD Ryzen 9 5950X; full tables and the data: [results/2026-10](results/2026-10).

### Measured
| stack | PostgreSQL, CPU per request: stack / DB / stack + DB | MySQL, CPU per request: stack / DB / stack + DB | memory per 1000 waiting requests |
|---|---:|---:|---:|
| Java Jetty 12, virtual threads | 0.30 / 0.52 / 0.82 ms | 0.40 / 1.12 / 1.52 ms | 0.44 GiB |
| Go net/http | 0.40 / 0.52 / 0.92 ms | 0.56 / 1.35 / 1.91 ms | 0.10 GiB |
| Python uvicorn | 0.40 / 0.58 / 0.98 ms | 0.43 / 1.18 / 1.61 ms | 0.02 GiB |
| Ruby Puma | 0.36 / 1.23 / 1.59 ms | 0.36 / 1.15 / 1.51 ms | 0.41 GiB |
| Node node:http | 0.37 / 1.26 / 1.64 ms | 0.35 / 1.19 / 1.53 ms | 0.90 GiB\* |
| Node Fastify | 0.39 / 1.27 / 1.65 ms | 0.37 / 1.20 / 1.57 ms | 0.84 GiB\* |
| Rust hyper | 0.27 / 1.44 / 1.71 ms | 0.27 / 1.32 / 1.59 ms | 0.08 GiB |
| PHP Swoole | 0.36 / 1.42 / 1.77 ms | 0.19 / 1.16 / 1.35 ms | 0.11 GiB |
| PHP FrankenPHP worker | 0.42 / 1.42 / 1.84 ms | 0.33 / 1.15 / 1.48 ms | 0.96 GiB |
| PHP RoadRunner | 0.51 / 1.47 / 1.98 ms | 0.38 / 1.21 / 1.59 ms | 11.49 GiB |
| PHP FPM + nginx | 0.51 / 1.50 / 2.01 ms | 0.41 / 1.27 / 1.67 ms | 1.13 GiB |
| .NET 10 Kestrel | 0.83 / 1.31 / 2.13 ms | 0.88 / 1.22 / 2.10 ms | 0.23 GiB |

CPU per request: CPU time of the stack's containers (with nginx where present) per request served, at a fixed 2000 req/s over 48 connections without waiting; "DB" is the CPU time of the database server per request. Memory: growth of the stack's memory per 1000 concurrent requests that each wait 1 s on another service (PostgreSQL; from 100 to 1000 concurrent requests, RoadRunner to 500). \* Node: up to 1000 concurrent requests; from 1000 to 5000 only 0.14 GiB more per 1000.

### Modelled
Nothing ran on these servers; the computation is below. The CPU per request here comes from the run with a 0.1 s wait (shown in the last column), not from the table above: a stack under a light, waiting load spends more CPU per request than at 2000 req/s.

| stack | modelled $/month, 1000 req/s, 0.1 s wait: stack / stack + DB | CPU per request in that run: stack / DB |
|---|---:|---:|
| Java Jetty 12, virtual threads | $21 / $53 | 0.46 / 0.71 ms |
| Go net/http | $17 / $49 | 0.38 / 0.71 ms |
| Python uvicorn | $26 / $55 | 0.59 / 0.64 ms |
| Ruby Puma | $23 / $79 | 0.50 / 1.25 ms |
| Node node:http | $23 / $79 | 0.50 / 1.26 ms |
| Node Fastify | $24 / $81 | 0.54 / 1.26 ms |
| Rust hyper | $15 / $80 | 0.34 / 1.44 ms |
| PHP Swoole | $19 / $79 | 0.42 / 1.35 ms |
| PHP FrankenPHP worker | $24 / $91 | 0.53 / 1.50 ms |
| PHP RoadRunner | $36 / $103 | 0.72 / 1.51 ms |
| PHP FPM + nginx | $29 / $98 | 0.65 / 1.54 ms |
| .NET 10 Kestrel | $46 / $105 | 1.03 / 1.32 ms |

> [!IMPORTANT]
> **These measurements are approximate.** They come from one machine, one load generator and one read-only API, and they describe this setup, not the languages in general. The configuration of each stack follows its documentation as well as we could apply it, but it may not be optimal and may change as mistakes are found; results are re-published when it does. Issues and pull requests that improve a stack are welcome, especially from people who run it in production — see [CONTRIBUTING.md](CONTRIBUTING.md).

### In short
- With every stack on its defaults, the database driver decides more than the runtime. At 2000 req/s on PostgreSQL, drivers that keep prepared statements per connection by default (PgJDBC, pgx, asyncpg) cost the database 0.52–0.58 ms per request; the others make it parse every statement (1.23–1.50 ms). Stack + database: Java 0.82 ms, Go 0.92 ms, Python 0.98 ms, every other stack 1.59–2.13 ms; in the model that is $49–55 against $79–105 per month for 1000 req/s with a 0.1 s wait. What each driver does, and which setting would change it, is in [docs/rules.md](docs/rules.md); turning those settings on for every stack is the tuning stage.
- On MySQL the order differs: stack + database is lowest for Swoole (1.35 ms) and FrankenPHP (1.48 ms), then Ruby, Java and Node node:http (1.51–1.53 ms); Go is last but one (1.91 ms, its driver prepares, executes and closes every statement).
- The runtimes themselves are within about 2× of each other on PostgreSQL (0.27–0.51 ms of CPU per request at 2000 req/s; on MySQL 0.19–0.56 ms). .NET spends 0.83 ms because its thread pool spins while waiting for work: its CPU per request falls from 0.97 ms at 1000 req/s to 0.70 ms at 4000 req/s, and with the spinning switched off (`DOTNET_ThreadPool_UnfairSemaphoreSpinLimit=0`, not a default) it is 0.32 ms (section 1b of the tables).
- PHP at 2000 req/s on PostgreSQL: Swoole 0.36 ms per request, FrankenPHP 0.42, FPM and RoadRunner 0.51 (on MySQL 0.19, 0.33, 0.41 and 0.38). Swoole is an extension with its own coroutine server, not the usual way PHP is deployed (FPM is). PDO's default on PostgreSQL — native prepares, a prepare, an execute and a close for every statement — is the most expensive of the four modes measured for FPM (section 6 of the tables, at 50 clients with the database saturated, hence higher figures than at 2000 req/s): stack + database 2.60 ms per request, against 2.13 ms with emulated prepares, 2.21 ms with `Pdo\Pgsql::ATTR_DISABLE_PREPARES` and 1.91 ms with native prepares through PgBouncer, which keeps the statements prepared on its server connections across requests.
- Memory per waiting request: a PHP worker per request costs 11.5 GiB per 1000 waiting requests on RoadRunner, 1.1 GiB on FPM and 0.96 GiB on FrankenPHP; Puma's threads 0.41 GiB; the event-loop and virtual-thread stacks 0.02–0.44 GiB (Node: 0.84–0.90 GiB up to 1000, then 0.14 GiB per 1000). RoadRunner starts every worker as a separate PHP process (exec), each with its own OPcache memory and heap; FPM forks its children from one master process, which share that memory copy-on-write.
- Swoole on PostgreSQL did not sustain 4000 req/s in 2 of its 5 attempts, and one of the 3 accepted attempts had a p99 of 1.7 s: probably because its pool of 3 connections per worker process queues requests at that rate (not measured separately).

### Good for, not good for
- **Good for:** comparing execution models (process or thread per request against event loops and virtual threads), the defaults of database drivers, and memory per waiting request; seeing where the CPU of a simple API request goes.
- **Not good for:** picking a language or a budget on its own. There are no frameworks, writes, caches, logging or business logic; the hardware is a desktop CPU over loopback, not cloud VMs; the dollars are a model with the assumptions listed below; team productivity is not in it.

## How the numbers are computed
- **Measured:** CPU per request — cgroup CPU time of the containers between snapshots right before and after the load run, divided by the requests served; memory per 1000 waiting requests — the growth of the stack's memory (anon + shmem + kernel at the peak) from 100 to 1000 concurrent requests (RoadRunner: 500) that each wait 1 s on a stub, per 1000 requests: the slope of the whole stack's resident memory, not the size of one request; it need not be linear (see Node).
- **Three CPU figures per stack.** The same stack spends a different CPU time per request under different loads, and each figure is used where its conditions apply: the measured table (2000 req/s, no waiting), the dollars (about 1000 req/s, each request waiting 0.1 s: section 3 of the tables), and the waiting series at 1000 concurrent requests waiting 1 s (section 2), where FPM, FrankenPHP and RoadRunner run 500–1000 workers behind PgBouncer. For PHP-FPM on PostgreSQL that is 0.51, 0.65 and 1.20 ms.
- **Modelled** ([results/2026-10/aggregate.py](results/2026-10/aggregate.py), sections 4 and 8 of the [tables](results/2026-10/tables.md)):
  - vCPU for 1000 req/s = CPU per request (s) × 1000 req/s / 0.6 (a 60% target CPU utilisation), with the CPU per request of the run with a 0.1 s wait (100 clients ≈ 1000 req/s);
  - concurrent requests = 1000 req/s × (0.1 s wait + about 0.01 s of processing) = 110 (Little's law);
  - memory = base × vCPU / 8 + memory per 1000 waiting requests × 110 / 1000; the base — memory at 100 clients minus the slope's share — is scaled with the vCPUs, which was not measured;
  - $/month = vCPU × $26.83 + GiB × $2.66: the AWS on-demand prices of c7i/m7i/r7i.xlarge (4 vCPU with 8, 16 and 32 GiB) fitted as a price per vCPU plus a price per GB; fractional vCPUs, no minimum instance size or spare capacity; "stack + DB" adds the database's CPU at the same vCPU price, not its memory or storage. Amortised resource prices, not a bill.
- Section 8 of the tables works through two rows with every intermediate number, for example PHP FPM: 0.650 ms × 1000 / 0.6 = 1.084 vCPU; 30 MiB × 1.084 / 8 + 1157 MiB × 0.11 = 131 MiB; 1.084 × $26.83 + 0.128 GiB × $2.66 = $29 per month. Section 5 extrapolates a ceiling for one 8-vCPU server, with the limits it leaves out.

## What is measured
- **The API** ([spec](spec/spec.md)): token authentication against the database, then a page of 20 posts with author, tags and comment count, or one post with its comments. Symfony Demo data ×100 (3000 posts) plus 1000 readers, in PostgreSQL 17 or MySQL 8.4.
- **12 implementations** ([implementations/](implementations)): PHP on FPM, FrankenPHP, RoadRunner and Swoole; Go `net/http`; Node `node:http` and Fastify; Rust hyper; Java Jetty 12 with virtual threads; .NET 10 Kestrel; Python uvicorn; Ruby Puma.
- **Three series** ([harness/](harness)): equal numbers of clients (1–200, closed loop, without waiting; memory and throughput), fixed request rates (1000, 2000 and 4000 req/s over 48 connections, without waiting; CPU per request at the same load for every stack, below the saturation of the database), and requests that each wait 0.1 s or 1 s on an external service — the case where memory per waiting request matters. In the waiting series the blocking models (FPM, FrankenPHP, RoadRunner, Puma threads) are provisioned for the load: one PHP worker per concurrent request, two Puma threads per concurrent request. It shows what each model needs to serve C waiting requests without a queue, not how a fixed production pool behaves under that load.
- Every stack must return the same responses (hashed before measuring); any 5xx under load rejects the run.

## Equal conditions
[docs/rules.md](docs/rules.md): runtime, server, driver and library defaults plus the vendors' documented production recommendations; the harness only sizes — the same process counts per CPU, 24 database connections per stack (PHP workers hold one each: FPM 32, FrankenPHP and RoadRunner 16), one connection per request (returned to the pool while the upstream is awaited; PHP workers hold one connection each), keep-alive to the upstream, a bounded Java heap. What each driver then does on the wire (prepared statements cached, prepared every time, or text queries) is listed there per stack.

## Limitations
- One machine (AMD Zen 3, boost on), stack on 4 cores, x86-64, with the databases and the load generator on the same host over loopback. In a deployment of several VMs, network interrupts and wake-ups across vCPUs add CPU per request, more for the models that wake on every database reply and for drivers with more exchanges per statement; a cloud check of this is a separate publication.
- One read-only API: no writes, cache, logging, tracing or business logic.
- In the series with equal numbers of clients the database is the bottleneck from about 50 clients (10.5–11.9 of its 12 threads busy at 200 clients on MySQL), so throughput there is close for all stacks; the fixed-rate series compares CPU per request below that point. The waiting series ran on PostgreSQL only.
- Latencies: the equal-clients and waiting series use closed-loop wrk (coordinated omission applies); the fixed-rate series uses wrk2, which corrects for it. Swoole's p99 stands out on PostgreSQL at 4000 req/s and at 200 clients ([tables](results/2026-10/tables.md), sections 1 and 1a).
- Memory per waiting request is the slope of one series: it mixes concurrency with throughput and, for garbage-collected runtimes, the heap policy, and it does not carry over to other loads (Node at about 1000 req/s with a 0.1 s wait uses about 1.35 GiB, twice what the model gives). It also varies between passes for Java (0.39–0.76 GiB per 1000) and .NET (0.17–0.25 GiB); section 3 of the tables lists the slope of each pass.
- wrk splits connections over its 4 threads rounded down: the 50 connections of the fixed-rate series and of C = 50 are 48, and C = 10 is 8.
- At least three passes of every series (Swoole on PostgreSQL has five at 1000 and 2000 req/s, from two rerun sweeps). Spread of stack CPU per request over the passes: equal clients 1.2% at the median, 3.4% at the 90th percentile, 6.9% at most; fixed rates 1.2%, 2.7% and 14.6%; waiting 1.5%, 4.2% and 8.6%.
- The implementations were written by the author with an AI assistant and checked for response equivalence; they have not yet been reviewed by each language's community — if yours looks suboptimal, please say so.
- The author contributes to PHP. The rules and the configuration of every stack are written down in [docs/rules.md](docs/rules.md) and apply the same way to all of them.

## Repository
| folder | content |
|---|---|
| [spec/](spec) | the API, data dumps, request lists |
| [implementations/](implementations) | one folder per language, each with a README (build, run, choices) |
| [harness/](harness) | stack configuration (`stack/up.sh`), measurement scripts, setup |
| [results/](results) | data, tables and the aggregation script of each series |
| [docs/rules.md](docs/rules.md) | the rules every stack follows |

## License
Code: [MIT](LICENSE). Data, tables and texts: [CC BY 4.0](LICENSE-DATA).
