# Node

`blog.mjs` holds the API logic (authentication, the two endpoints, the upstream call); `server.mjs` starts a `cluster` of `BLOG_WORKERS` processes and serves it with `node:http` (`BLOG_SERVER=http`, one handler that routes by path) or Fastify (`BLOG_SERVER=fastify`: authentication in an `onRequest` hook, routes `/posts` and `/posts/:slug` with response schemas, a not-found handler). PostgreSQL through `pg` and MySQL through `mysql2`, both with `query(sql, values)` (pg: unnamed statement; mysql2: values escaped on the client). Pool of `BLOG_POOL` connections per process; the statements of a request share one connection (`pool.connect()` / `getConnection()`), released while the upstream is awaited (Fastify: taken in `onRequest`, released in `onResponse`). The upstream call uses `http.get` with a keep-alive `http.Agent` without a socket limit.

```sh
npm ci                      # Node 24.22.0
BLOG_SERVER=http BLOG_WORKERS=8 BLOG_DRIVER=pg BLOG_DSN=postgres://postgres:bench@127.0.0.1:55440/bench \
  BLOG_POOL=3 BLOG_ADDR=127.0.0.1:8082 node server.mjs
```
The stack mounts Node from `NODE_HOME` (default `~/.nvm/versions/node/v24.22.0`, where `nvm install 24.22.0` puts it) into the container.
