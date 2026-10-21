# Driver settings within one stack, October 2026

Stage 1 compares stacks on their drivers' defaults. This series changes one connection-string option of one driver and keeps everything else: the same stack, database, harness, machine and CPUs as [`../2026-10`](../2026-10/README.md), at a fixed 2000 req/s over 48 connections (wrk2, warm-up 15 s, measured 20 s). It checks whether the database cost of a stack moves with the driver's statement handling alone.

| stack | database | option | what it changes |
|---|---|---|---|
| Go `net/http`, pgx | PostgreSQL | `?default_query_exec_mode=exec` | pgx stops caching prepared statements and sends each statement as an unnamed one |
| Go `net/http`, go-sql-driver | MySQL | `?interpolateParams=true` | one text query per statement instead of prepare, execute and close |
| .NET 10 Kestrel, Npgsql | PostgreSQL | `;Max Auto Prepare=20` | Npgsql prepares a statement on the server after 5 uses (the default `Auto Prepare Min Usages`) and keeps it |

Each pass runs the six configurations (three defaults, three options) in a new shuffled order, 3 passes, on 22 October 2026 on the same Ryzen 9 5950X. CPU per request as in `../2026-10`: cgroup CPU between the snapshots around wrk divided by the requests completed. Median of the passes, [min–max]:

| stack | db | option | passes | stack CPU, ms | DB CPU, ms | stack + DB, ms | p99, ms |
|---|---|---|---:|---:|---:|---:|---:|
| .NET | pgsql | `;Max Auto Prepare=20` | 3 | 0.770 [0.765–0.774] | 0.594 [0.587–0.598] | 1.361 [1.359–1.368] | 3.6 |
| .NET | pgsql | default | 3 | 0.825 [0.813–0.828] | 1.293 [1.276–1.293] | 2.106 [2.104–2.119] | 5.8 |
| Go | mysql | `?interpolateParams=true` | 3 | 0.420 [0.420–0.430] | 1.122 [1.119–1.145] | 1.542 [1.539–1.576] | 5.5 |
| Go | mysql | default | 3 | 0.575 [0.560–0.575] | 1.320 [1.317–1.337] | 1.892 [1.881–1.913] | 5.8 |
| Go | pgsql | `?default_query_exec_mode=exec` | 3 | 0.403 [0.350–0.405] | 1.205 [1.183–1.217] | 1.585 [1.567–1.610] | 5.8 |
| Go | pgsql | default | 3 | 0.403 [0.397–0.408] | 0.526 [0.513–0.530] | 0.929 [0.910–0.939] | 3.4 |

The defaults repeat the stage 1 numbers within 2% (Go 0.92 / 1.91 ms, .NET 2.13 ms at 2000 req/s in `../2026-10/tables.md`).

- `run.sh` runs the series (`PASSES=3 ./run.sh`, harness in `../../harness`, CPU sets as in the stage 1 README).
- `summary.py data/*.jsonl` prints the table above.
- `data/` holds the raw records and logs of `matrix.sh`; the option is in each record's `env` field.
