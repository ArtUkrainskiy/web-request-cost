# Blog API — Java, no framework

The task from `spec/spec.md`, mirroring `implementations/go/main.go`: same SQL in the same order,
same JSON bytes, authentication before routing, optional upstream call (`BLOG_UPSTREAM`).

- Temurin JDK 25.0.4.1+1 (current LTS), one JVM process
- Jetty 12.1.14 core `Handler` (no servlets); `QueuedThreadPool` with a virtual-thread executor, so the
  blocking handler runs on a virtual thread per request, selectors on platform threads
- plain JDBC: PgJDBC 42.7.14, MySQL Connector/J 26.7.0, HikariCP 7.1.0, pool of `BLOG_POOL` (24); one connection per request,
  closed (returned to the pool) while the upstream is awaited
- Jackson 3.2.3 databind (records, snake_case names, declaration order)
- upstream: `java.net.http.HttpClient`, HTTP/1.1, keep-alive pool

## Build

Temurin JDK 25.0.4.1+1 (https://adoptium.net, Linux x64 tar.gz) unpacked into `~/.local/jdk-25.0.4.1+1`, the default
`JAVA_HOME_BLOG` of `harness/stack/up.sh`, and Maven 3.10.0 (https://maven.apache.org/download.cgi):

    export JAVA_HOME=~/.local/jdk-25.0.4.1+1
    mvn -q -B package    # → target/blog.jar (fat jar)

## Run

    BLOG_DRIVER=pg BLOG_POOL=24 BLOG_ADDR=127.0.0.1:8099 \
    BLOG_DSN='jdbc:postgresql://127.0.0.1:55440/bench?user=postgres&password=bench&sslmode=disable' \
    $JAVA_HOME/bin/java -XX:+UseG1GC -Xms64m -Xmx2g -XX:+ExitOnOutOfMemoryError -jar target/blog.jar

MySQL: `BLOG_DRIVER=mysql BLOG_DSN='jdbc:mysql://127.0.0.1:53340/bench?user=root&password=bench&sslMode=DISABLED&allowPublicKeyRetrieval=true&useServerPrepStmts=true'`.

DSN options: TLS off as in the Go, Node and PHP stacks (Connector/J would otherwise negotiate TLS with
MySQL 8.4); `useServerPrepStmts=true` makes Connector/J use native prepared statements.
Statements: `Main.java` sets the HikariCP wiki's MySQL properties (`cachePrepStmts=true`,
`prepStmtCacheSize=250`, `prepStmtCacheSqlLimit=2048`, `useServerPrepStmts=true`), which keeps server-side
prepared statements per connection; PgJDBC runs with its defaults (a statement becomes server-side prepared
after 5 executions on a connection, `prepareThreshold`).

JVM flags: the heap is capped explicitly, because under the stack's 40 GB container limit the
default ergonomics give a 10 GB maximum heap and a 640 MB initial heap. `-Xmx2g`: the live set is a
few tens of MB at low concurrency, but 5000 requests waiting on the upstream (virtual-thread stacks
live on the heap) do not fit into a 512 MB heap; `-Xms64m` lets G1 grow the heap only when its GC-time
goal needs it.
G1 is pinned so the collector does not change with the CPU count, and a heap OOM exits the process
(the container restarts it) instead of leaving it half-alive.
