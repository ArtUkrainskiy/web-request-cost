// Blog API from spec/spec.md, "bare" Java: a Jetty 12 core Handler (no servlets) whose blocking
// code runs on virtual threads, plain JDBC (PgJDBC / MySQL Connector/J) through a HikariCP pool of
// BLOG_POOL connections, Jackson 3 databind for JSON, java.net.http for the optional upstream call.
// Mirrors implementations/go/main.go: same SQL in the same order, one pool checkout per query.
//
//   BLOG_DRIVER=pg|mysql BLOG_DSN=jdbc:... BLOG_POOL=24 BLOG_ADDR=127.0.0.1:8099 java -jar blog.jar
package blog;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executors;
import org.eclipse.jetty.http.HttpHeader;
import org.eclipse.jetty.server.Handler;
import org.eclipse.jetty.server.HttpConfiguration;
import org.eclipse.jetty.server.HttpConnectionFactory;
import org.eclipse.jetty.server.Request;
import org.eclipse.jetty.server.Response;
import org.eclipse.jetty.server.Server;
import org.eclipse.jetty.server.ServerConnector;
import org.eclipse.jetty.util.Callback;
import org.eclipse.jetty.util.thread.QueuedThreadPool;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import tools.jackson.databind.MapperFeature;
import tools.jackson.databind.PropertyNamingStrategies;
import tools.jackson.databind.json.JsonMapper;

public final class Main {
    // The spec's fixed "now", so that runs are reproducible.
    static final LocalDateTime NOW = LocalDateTime.of(2026, 10, 13, 0, 0, 0);

    record User(long id, String username) {}

    record Author(long id, String name) {}

    record ListPost(long id, String title, String slug, String summary, String publishedAt, Author author,
            List<String> tags, long commentCount) {}

    record ListResponse(User user, int page, List<ListPost> posts) {}

    record Comment(long id, String author, String content, String publishedAt) {}

    record Post(long id, String title, String slug, String summary, String content, String publishedAt,
            Author author, List<String> tags, List<Comment> comments) {}

    record PostResponse(User user, Post post) {}

    record ErrorBody(String error) {}

    // Record components in declaration order, camelCase → snake_case; Jackson does not escape '/' or
    // non-ASCII by default.
    static final JsonMapper JSON = JsonMapper.builder()
            .propertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE)
            .disable(MapperFeature.SORT_PROPERTIES_ALPHABETICALLY)
            .build();
    static final Logger LOG = LoggerFactory.getLogger("blog");
    static final String UPSTREAM = System.getenv().getOrDefault("BLOG_UPSTREAM", "");
    static final HttpClient UPSTREAM_CLIENT = HttpClient.newBuilder()
            .version(HttpClient.Version.HTTP_1_1)
            .executor(Executors.newVirtualThreadPerTaskExecutor())
            .build();
    static final byte[] UPSTREAM_OK = "{\"ok\":true}".getBytes(StandardCharsets.US_ASCII);

    static boolean pg;
    static HikariDataSource ds;
    static String authSql, listSql, tagsInSql, countsInSql, postSql, tagsSql, commentsSql;

    static String atom(String s) {
        return s.substring(0, 10) + "T" + s.substring(11) + "+00:00";
    }

    static String at(String col) {
        return pg ? "to_char(" + col + ", 'YYYY-MM-DD HH24:MI:SS')" : "DATE_FORMAT(" + col + ", '%Y-%m-%d %H:%i:%s')";
    }

    static String placeholders(int n) {
        return String.join(", ", Collections.nCopies(n, "?"));
    }

    static void bind(PreparedStatement st, Object... args) throws SQLException {
        for (int i = 0; i < args.length; i++) {
            st.setObject(i + 1, args[i]);
        }
    }

    static void reply(Response response, Callback callback, int status, Object v) {
        byte[] body = JSON.writeValueAsBytes(v);
        response.setStatus(status);
        response.getHeaders().put(HttpHeader.CONTENT_TYPE, "application/json");
        response.getHeaders().put(HttpHeader.CONTENT_LENGTH, body.length);
        response.write(true, ByteBuffer.wrap(body), callback);
    }

    // auth runs for every request, before routing, as in the spec; null means 401.
    static User auth(Connection c, Request request) throws Exception {
        String header = request.getHeaders().get(HttpHeader.AUTHORIZATION);
        String token = header != null && header.length() > 7 ? header.substring(7) : "";
        String hash = HexFormat.of().formatHex(
                MessageDigest.getInstance("SHA-256").digest(token.getBytes(StandardCharsets.UTF_8)));
        User user = null;
        try (PreparedStatement st = c.prepareStatement(authSql)) {
            bind(st, hash, NOW);
            try (ResultSet rs = st.executeQuery()) {
                if (rs.next()) {
                    user = new User(rs.getLong(1), rs.getString(2));
                }
            }
        }
        if (header == null || !header.startsWith("Bearer ") || user == null) {
            return null;
        }
        return user;
    }

    static void callUpstream() throws Exception {
        if (!UPSTREAM.isEmpty()) {
            HttpResponse<byte[]> resp = UPSTREAM_CLIENT.send(
                    HttpRequest.newBuilder(URI.create(UPSTREAM)).GET().build(), HttpResponse.BodyHandlers.ofByteArray());
            if (!java.util.Arrays.equals(resp.body(), UPSTREAM_OK)) {
                throw new IllegalStateException("upstream: " + new String(resp.body(), StandardCharsets.UTF_8));
            }
        }
    }

    static void listPosts(Connection c, Request request, Response response, Callback callback, User user) throws SQLException {
        int page = 1;
        String v = Request.extractQueryParameters(request).getValue("page");
        if (v != null && !v.isEmpty()) {
            try {
                page = Integer.parseInt(v);
            } catch (NumberFormatException e) {
                page = 0; // as Go's strconv.Atoi: the query then fails on a negative OFFSET
            }
        }
        record Row(long id, String title, String slug, String summary, String publishedAt, Author author) {}
        List<Row> rows = new ArrayList<>(20);
        try (PreparedStatement st = c.prepareStatement(listSql)) {
            bind(st, (page - 1) * 20);
            try (ResultSet rs = st.executeQuery()) {
                while (rs.next()) {
                    rows.add(new Row(rs.getLong(1), rs.getString(2), rs.getString(3), rs.getString(4),
                            atom(rs.getString(5)), new Author(rs.getLong(6), rs.getString(7))));
                }
            }
        }
        Map<Long, List<String>> tags = new HashMap<>();
        Map<Long, Long> counts = new HashMap<>();
        if (!rows.isEmpty()) {
            Object[] ids = new Object[rows.size()];
            for (int i = 0; i < ids.length; i++) {
                ids[i] = rows.get(i).id();
            }
            String in = placeholders(ids.length);
            try (PreparedStatement st = c.prepareStatement(tagsInSql.replace("?", in))) {
                bind(st, ids);
                try (ResultSet rs = st.executeQuery()) {
                    while (rs.next()) {
                        tags.computeIfAbsent(rs.getLong(1), k -> new ArrayList<>()).add(rs.getString(2));
                    }
                }
            }
            try (PreparedStatement st = c.prepareStatement(countsInSql.replace("?", in))) {
                bind(st, ids);
                try (ResultSet rs = st.executeQuery()) {
                    while (rs.next()) {
                        counts.put(rs.getLong(1), rs.getLong(2));
                    }
                }
            }
        }
        List<ListPost> posts = new ArrayList<>(rows.size());
        for (Row r : rows) {
            posts.add(new ListPost(r.id(), r.title(), r.slug(), r.summary(), r.publishedAt(), r.author(),
                    tags.getOrDefault(r.id(), List.of()), counts.getOrDefault(r.id(), 0L)));
        }
        reply(response, callback, 200, new ListResponse(user, page, posts));
    }

    static void showPost(Connection c, Response response, Callback callback, User user, String slug) throws SQLException {
        long id;
        String title, postSlug, summary, content, publishedAt;
        Author author;
        try (PreparedStatement st = c.prepareStatement(postSql)) {
            bind(st, slug);
            try (ResultSet rs = st.executeQuery()) {
                if (!rs.next()) {
                    reply(response, callback, 404, new ErrorBody("not found"));
                    return;
                }
                id = rs.getLong(1);
                title = rs.getString(2);
                postSlug = rs.getString(3);
                summary = rs.getString(4);
                content = rs.getString(5);
                publishedAt = atom(rs.getString(6));
                author = new Author(rs.getLong(7), rs.getString(8));
            }
        }
        List<String> tags = new ArrayList<>();
        try (PreparedStatement st = c.prepareStatement(tagsSql)) {
            bind(st, id);
            try (ResultSet rs = st.executeQuery()) {
                while (rs.next()) {
                    tags.add(rs.getString(1));
                }
            }
        }
        List<Comment> comments = new ArrayList<>();
        try (PreparedStatement st = c.prepareStatement(commentsSql)) {
            bind(st, id);
            try (ResultSet rs = st.executeQuery()) {
                while (rs.next()) {
                    comments.add(new Comment(rs.getLong(1), rs.getString(2), rs.getString(3), atom(rs.getString(4))));
                }
            }
        }
        reply(response, callback, 200, new PostResponse(user,
                new Post(id, title, postSlug, summary, content, publishedAt, author, tags, comments)));
    }

    // Blocking handler (the default invocation type of Handler.Abstract): Jetty calls it on a virtual thread.
    static final class Blog extends Handler.Abstract {
        @Override
        public boolean handle(Request request, Response response, Callback callback) {
            // The statements of a request share one connection, returned to the pool while the upstream is awaited.
            Connection c = null;
            try {
                c = ds.getConnection();
                User user = auth(c, request);
                if (user == null) {
                    reply(response, callback, 401, new ErrorBody("unauthorized"));
                    return true;
                }
                if (!UPSTREAM.isEmpty()) {
                    c.close();
                    c = null;
                    callUpstream();
                    c = ds.getConnection();
                }
                String path = request.getHttpURI().getDecodedPath();
                boolean get = "GET".equals(request.getMethod()) || "HEAD".equals(request.getMethod());
                if (get && "/posts".equals(path)) {
                    listPosts(c, request, response, callback, user);
                } else if (get && path.startsWith("/posts/") && path.length() > 7 && path.indexOf('/', 7) < 0) {
                    showPost(c, response, callback, user, path.substring(7));
                } else {
                    reply(response, callback, 404, new ErrorBody("not found"));
                }
            } catch (Throwable e) {
                LOG.warn("request failed", e);
                if (!response.isCommitted()) {
                    response.setStatus(500);
                    response.getHeaders().put(HttpHeader.CONTENT_LENGTH, 0L);
                    response.write(true, null, callback);
                } else {
                    callback.failed(e);
                }
            } finally {
                if (c != null) {
                    try {
                        c.close();
                    } catch (SQLException e) {
                        LOG.warn("connection close failed", e);
                    }
                }
            }
            return true;
        }
    }

    public static void main(String[] args) throws Exception {
        String driver = System.getenv().getOrDefault("BLOG_DRIVER", "pg");
        pg = driver.equals("pg") || driver.equals("pgsql") || driver.equals("pgx");
        int size = 20;
        try {
            size = Integer.parseInt(System.getenv().getOrDefault("BLOG_POOL", "24"));
        } catch (NumberFormatException e) {
            // keep 20
        }
        if (size <= 0) {
            size = 20;
        }
        authSql = "SELECT u.id, u.username FROM blog_session s JOIN symfony_demo_user u ON u.id = s.user_id WHERE s.token_hash = ? AND s.expires_at > ?";
        listSql = "SELECT p.id, p.title, p.slug, p.summary, " + at("p.published_at")
                + ", u.id, u.full_name FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id ORDER BY p.published_at DESC LIMIT 20 OFFSET ?";
        tagsInSql = "SELECT pt.post_id, t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id WHERE pt.post_id IN (?) ORDER BY pt.post_id, t.name";
        countsInSql = "SELECT post_id, COUNT(*) FROM symfony_demo_comment WHERE post_id IN (?) GROUP BY post_id";
        postSql = "SELECT p.id, p.title, p.slug, p.summary, p.content, " + at("p.published_at")
                + ", u.id, u.full_name FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id WHERE p.slug = ?";
        tagsSql = "SELECT t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id WHERE pt.post_id = ? ORDER BY t.name";
        commentsSql = "SELECT c.id, u.full_name, c.content, " + at("c.published_at")
                + " FROM symfony_demo_comment c JOIN symfony_demo_user u ON u.id = c.author_id WHERE c.post_id = ? ORDER BY c.published_at, c.id";

        HikariConfig cfg = new HikariConfig();
        cfg.setJdbcUrl(System.getenv("BLOG_DSN"));
        cfg.setMaximumPoolSize(size);
        cfg.setPoolName("blog");
        // PgJDBC with its defaults; Connector/J with the HikariCP wiki's MySQL configuration
        // (https://github.com/brettwooldridge/HikariCP/wiki/MySQL-Configuration).
        if (!pg) {
            cfg.addDataSourceProperty("cachePrepStmts", "true");
            cfg.addDataSourceProperty("prepStmtCacheSize", "250");
            cfg.addDataSourceProperty("prepStmtCacheSqlLimit", "2048");
            cfg.addDataSourceProperty("useServerPrepStmts", "true");
        }
        ds = new HikariDataSource(cfg); // opens the pool and fails fast if the database is unreachable

        String addr = System.getenv().getOrDefault("BLOG_ADDR", "127.0.0.1:8099");
        int colon = addr.lastIndexOf(':');
        QueuedThreadPool threads = new QueuedThreadPool();
        threads.setName("jetty");
        threads.setVirtualThreadsExecutor(Executors.newVirtualThreadPerTaskExecutor());
        Server server = new Server(threads);
        HttpConfiguration http = new HttpConfiguration();
        http.setSendServerVersion(false);
        ServerConnector connector = new ServerConnector(server, new HttpConnectionFactory(http));
        connector.setHost(addr.substring(0, colon));
        connector.setPort(Integer.parseInt(addr.substring(colon + 1)));
        connector.setAcceptQueueSize(4096);
        server.addConnector(connector);
        server.setHandler(new Blog());
        server.setStopAtShutdown(true);
        server.start();
        System.out.println("listening " + addr);
        server.join();
    }
}
