# Go

`main.go`: `net/http` with Go 1.22 routing, one process. PostgreSQL through `pgxpool` (pgx caches prepared statements per connection by default), MySQL through `database/sql` + go-sql-driver (`QueryContext`: the driver prepares, executes and closes every statement). Pool of `BLOG_POOL` connections (24 in the stack), `encoding/json` with its defaults. The statements of a request run on one connection (`pool.Acquire` / `db.Conn`), released while the upstream is awaited. The SQL text of every statement is built once at start (the `IN` lists for 1–20 ids). The upstream call goes through an `http.Transport` that keeps any number of idle keep-alive connections.

```sh
go build -o blog .          # Go 1.27.2; the stack mounts this folder and runs ./blog
BLOG_DRIVER=pgx BLOG_DSN=postgres://postgres:bench@127.0.0.1:55440/bench BLOG_POOL=24 BLOG_ADDR=127.0.0.1:8081 ./blog
```
