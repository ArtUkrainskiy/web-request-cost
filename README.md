# web-request-cost

How much CPU, memory and money one web request costs on different language runtimes — the same JSON API implemented without frameworks in PHP, Go, Node, Rust, Java, .NET, Python and Ruby, measured on one machine with the same database access rules and checked responses.

**Status: stage 1, bare runtimes with their defaults** — every stack as its vendors ship it, plus the settings their documentation recommends for production; tuning is a later stage. Frameworks (Laravel, Symfony, NestJS, Spring, ASP.NET MVC, FastAPI, axum, Rails, …) are the next stage.

> [!IMPORTANT]
> **These measurements are approximate.** They come from one machine, one load generator and one read-only API, and they describe this setup, not the languages in general. The configuration of each stack follows its documentation as well as we could apply it, but it may not be optimal and may change as mistakes are found; results are re-published when it does. Issues and pull requests that improve a stack are welcome, especially from people who run it in production — see [CONTRIBUTING.md](CONTRIBUTING.md).

## What is measured
- **The API** ([spec](spec/spec.md)): token authentication against the database, then a page of 20 posts with author, tags and comment count, or one post with its comments. Symfony Demo data ×100 (3000 posts) plus 1000 readers, in PostgreSQL 17 or MySQL 8.4.
- **12 implementations** ([implementations/](implementations)): PHP on FPM, FrankenPHP, RoadRunner and Swoole; Go `net/http`; Node `node:http` and Fastify; Rust hyper; Java Jetty 12 with virtual threads; .NET 10 Kestrel; Python uvicorn; Ruby Puma.
- **Two series** ([harness/](harness)): equal numbers of clients (1–200) without waiting, and requests that each wait 0.1 s or 1 s on an external service — the case where memory per waiting request matters. In the waiting series the blocking models (FPM, FrankenPHP, RoadRunner, Puma threads) are provisioned for the load: one PHP worker per concurrent request, two Puma threads per concurrent request. It shows what each model needs to serve C waiting requests without a queue, not how a fixed production pool behaves under that load.
- Every stack must return the same responses (hashed before measuring); any 5xx under load rejects the run.

## Results (PostgreSQL)
Stack on 4 cores / 8 threads of an AMD Ryzen 9 5950X. Full tables, MySQL and the data: [results/2026-10](results/2026-10).

| stack | CPU per request (50 clients) | modelled $/month for 1000 req/s with a 0.1 s wait: stack / stack + DB | memory per 1000 waiting requests | modelled ceiling, req/s on 8 vCPU with a 1 s wait |
|---|---:|---|---:|---:|
| Rust hyper | 0.32 ms | $10 / $52 | 0.08 GB | 20 936 |
| Java Jetty 12, virtual threads | 0.32 ms | $14 / $33 | 0.47 GB | 16 079 |
| Go net/http | 0.32 ms | $11 / $30 | 0.10 GB | 20 071 |
| PHP Swoole | 0.39 ms | $12 / $52 | 0.11 GB | 16 447 |
| Node node:http | 0.40 ms | $15 / $51 | 0.90 GB* | 13 857 |
| Node Fastify | 0.42 ms | $16 / $52 | 0.80 GB* | 14 278 |
| PHP FrankenPHP worker | 0.46 ms | $30 / $51 | 0.95 GB | 7 186 |
| Ruby Puma | 0.47 ms | $15 / $51 | 0.40 GB | 12 229 |
| Python uvicorn | 0.50 ms | $17 / $35 | 0.02 GB | 11 864 |
| PHP RoadRunner | 0.59 ms | $39 / $60 | 11.47 GB | 2 588 (memory-bound) |
| PHP FPM + nginx | 0.60 ms | $34 / $54 | 1.12 GB | 6 111 |
| .NET 10 Kestrel | 0.65 ms | $30 / $68 | 0.23 GB | 7 410 |

\* Node: up to 1000 concurrent requests; from 1000 to 5000 only 0.13–0.15 GB more per 1000.

Terms:
- **CPU per request** (measured): cgroup CPU time of the stack's containers (with nginx and PgBouncer where present) divided by the requests served, at 50 clients without waiting.
- **Memory per 1000 waiting requests** (measured): growth of the stack's memory (anon + shmem + kernel at the peak) from 100 to 1000 concurrent requests (RoadRunner: 500) that each wait 1 s, per 1000 requests — the slope of the whole stack's resident memory (workers, buffers, GC retention), not the size of one request; it need not be linear (see Node).
- **$/month** and **req/s on 8 vCPU** (modelled): derived from the measured CPU and memory per request; nothing ran on an 8-vCPU server. The ceiling assumes CPU per request stays as measured at much higher concurrency and that nothing else (the database included) limits first; the highest measured point is 5000 concurrent requests with a 1 s wait, i.e. at most ~5000 req/s. The memory part of the cost scales the base memory of a stack with its vCPUs (fewer processes on a smaller server), which was not measured. The dollars are amortised resource prices, not a bill: "stack + DB" adds the database's CPU, not its memory or storage.
- **Prices**: AWS EC2 on-demand c7i/m7i/r7i.xlarge decomposed into a vCPU price ($26.8/month) and a GB price ($2.66/month) at 94% utilisation; "stack + DB" adds the database's CPU at the same vCPU price. "0.1 s wait" is measured directly: 100 clients whose requests each wait 100 ms on a stub ≈ 1000 req/s.

Briefly:
- With every stack on its defaults, the database driver decides more than the runtime. Drivers that keep prepared statements per connection by default (pgx, PgJDBC, asyncpg) cost PostgreSQL 0.78–0.83 ms per request; the others make it parse every statement (1.79–2.05 ms). Counting the database, Go, Java and Python cost $30–35 per month for 1000 req/s with a 0.1 s wait, every other stack $51–68. The runtimes themselves are within about 2× of each other (0.32–0.65 ms of CPU per request).
- PHP: Swoole spends 0.39 ms per request, FrankenPHP 0.46, FPM and RoadRunner about 0.6. Swoole is an extension with its own coroutine server, not the usual way PHP is deployed (FPM is). PDO's default on PostgreSQL — native prepares, a prepare, an execute and a close for every statement — is the most expensive of the four modes measured for FPM (section 6 of the tables): stack + database 2.64 ms per request, against 2.15 ms with emulated prepares and 1.91 ms with native prepares through PgBouncer, which keeps the statements prepared on its server connections across requests.
- Memory per waiting request separates the models: a worker per request costs 11.5 GB per 1000 waiting requests on RoadRunner (every worker a separate process), about 1 GB on FPM and FrankenPHP, against 0.02–0.47 GB for the event-loop and virtual-thread stacks (Node: 0.8–0.9 GB up to 1000, then 0.13–0.15 GB per 1000).

## Equal conditions
[docs/rules.md](docs/rules.md): runtime, server, driver and library defaults plus the vendors' documented production recommendations; the harness only sizes — the same process counts per CPU, 24 database connections per stack, one connection per request (returned to the pool while the upstream is awaited; PHP workers hold one connection each), keep-alive to the upstream, a bounded Java heap. What each driver then does on the wire (prepared statements cached, prepared every time, or text queries) is listed there per stack.

## Limitations
- One machine (AMD Zen 3, boost on), stack on 4 cores, x86-64, with the databases and the load generator on the same host over loopback. In a deployment of several VMs, network interrupts and wake-ups across vCPUs add CPU per request, more for the models that wake on every database reply and for drivers with more exchanges per statement; a cloud check of this is a separate publication. Closed-loop load (wrk) with the usual coordinated-omission caveat for latencies.
- One read-only API: no writes, cache, logging, tracing or business logic.
- MySQL results are in the results folder. There the database is the bottleneck (11.1–11.9 of its 12 threads busy at 200 clients); stack CPU per request ranges from 0.21 ms (Swoole) to 0.70 ms (Go: go-sql-driver prepares, executes and closes every statement) and 0.75 ms (.NET).
- Both series: three passes. Spread of stack CPU per request over the passes: memory series 1.1% at the median, 4.5% at the 90th percentile, 8.5% at most; waiting series 1.7%, 4.1% and 10.2%.
- The implementations were written by the author with an AI assistant and checked for response equivalence; they have not yet been reviewed by each language's community — if yours looks suboptimal, please say so.
- The author contributes to PHP. The rules, configuration audits and methodology reviews were done before measuring to keep that out of the setup.

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
