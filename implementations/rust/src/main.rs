// Blog API from spec/spec.md, "bare" Rust: hyper 1.x on a multi-threaded tokio runtime,
// no framework, no ORM. PostgreSQL through tokio-postgres + deadpool-postgres (query(&str): a statement is
// prepared for every query), MySQL through mysql_async (its per-connection statement cache).
// One process, pool of BLOG_POOL connections.
//
//    BLOG_DRIVER=pg|mysql BLOG_DSN=... BLOG_POOL=24 BLOG_ADDR=127.0.0.1:8097 [BLOG_UPSTREAM=url] ./blog
use std::borrow::Cow;
use std::convert::Infallible;
use std::error::Error as StdError;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use deadpool_postgres::{Manager, ManagerConfig, Pool as PgPool, RecyclingMethod};
use http_body_util::{BodyExt, Empty, Full};
use hyper::body::Incoming;
use hyper::header::{AUTHORIZATION, CONTENT_TYPE, HeaderValue};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode, Uri};
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::rt::{TokioExecutor, TokioIo};
use mysql_async::prelude::Queryable;
use mysql_async::{Opts, OptsBuilder, PoolConstraints, PoolOpts, Value};
use serde::Serialize;
use sha2::{Digest, Sha256};
use tokio::net::TcpListener;
use tokio_postgres::NoTls;
use tokio_postgres::types::ToSql;

type BoxError = Box<dyn StdError + Send + Sync>;
type Result<T> = std::result::Result<T, BoxError>;

const NOW: &str = "2026-10-13 00:00:00";
const NOW_UNIX: u64 = 1_791_849_600; // NOW as seconds since the Unix epoch (UTC)

#[derive(Serialize)]
struct User {
    id: i64,
    username: String,
}

#[derive(Serialize)]
struct Author {
    id: i64,
    name: String,
}

#[derive(Serialize)]
struct ListPost {
    id: i64,
    title: String,
    slug: String,
    summary: String,
    published_at: String,
    author: Author,
    tags: Vec<String>,
    comment_count: i64,
}

#[derive(Serialize)]
struct ListResponse {
    user: User,
    page: i64,
    posts: Vec<ListPost>,
}

#[derive(Serialize)]
struct Comment {
    id: i64,
    author: String,
    content: String,
    published_at: String,
}

#[derive(Serialize)]
struct Post {
    id: i64,
    title: String,
    slug: String,
    summary: String,
    content: String,
    published_at: String,
    author: Author,
    tags: Vec<String>,
    comments: Vec<Comment>,
}

#[derive(Serialize)]
struct PostResponse {
    user: User,
    post: Post,
}

#[derive(Serialize)]
struct ErrorBody {
    error: &'static str,
}

enum Db {
    Pg(PgPool),
    My(mysql_async::Pool),
}

/// The connection of a request: its statements share it, and it goes back to the pool while the
/// upstream is awaited.
enum Conn {
    Pg(deadpool_postgres::Object),
    My(mysql_async::Conn),
}

/// A query parameter. `Now` is the fixed "now": a timestamp for PostgreSQL (tokio-postgres checks
/// parameter types, so a string is not accepted for a timestamp column), the string for MySQL.
enum P<'a> {
    I(i64),
    S(&'a str),
    Now,
}

/// Column access shared by both drivers' rows.
trait Row {
    fn int(&mut self, i: usize) -> Result<i64>;
    fn str(&mut self, i: usize) -> Result<String>;
}

impl Row for tokio_postgres::Row {
    fn int(&mut self, i: usize) -> Result<i64> {
        Ok(self.try_get(i)?)
    }
    fn str(&mut self, i: usize) -> Result<String> {
        Ok(self.try_get(i)?)
    }
}

impl Row for mysql_async::Row {
    fn int(&mut self, i: usize) -> Result<i64> {
        Ok(self.take_opt(i).ok_or("no column")??)
    }
    fn str(&mut self, i: usize) -> Result<String> {
        Ok(self.take_opt(i).ok_or("no column")??)
    }
}

struct App {
    db: Db,
    now: SystemTime,
    upstream: Option<(Client<HttpConnector, Empty<Bytes>>, Uri)>,
}

impl App {
    fn pg(&self) -> bool {
        matches!(self.db, Db::Pg(_))
    }

    /// Turns ? placeholders into $1, $2, … for PostgreSQL.
    fn q<'s>(&self, s: &'s str) -> Cow<'s, str> {
        if !self.pg() {
            return Cow::Borrowed(s);
        }
        let mut out = String::with_capacity(s.len() + 16);
        let mut n = 0;
        for c in s.chars() {
            if c == '?' {
                n += 1;
                out.push('$');
                out.push_str(&n.to_string());
            } else {
                out.push(c);
            }
        }
        Cow::Owned(out)
    }

    fn at(&self, col: &str) -> String {
        if self.pg() {
            format!("to_char({col}, 'YYYY-MM-DD HH24:MI:SS')")
        } else {
            format!("DATE_FORMAT({col}, '%Y-%m-%d %H:%i:%s')")
        }
    }

    async fn conn(&self) -> Result<Conn> {
        Ok(match &self.db {
            Db::Pg(pool) => Conn::Pg(pool.get().await?),
            Db::My(pool) => Conn::My(pool.get_conn().await?),
        })
    }

    /// Runs one query on the request's connection and maps every row with `f`.
    async fn query<T>(&self, c: &mut Conn, sql: &str, params: &[P<'_>], mut f: impl FnMut(&mut dyn Row) -> Result<T>) -> Result<Vec<T>> {
        let sql = self.q(sql);
        match c {
            Conn::Pg(client) => {
                let args: Vec<&(dyn ToSql + Sync)> = params
                    .iter()
                    .map(|p| match p {
                        P::I(v) => v as &(dyn ToSql + Sync),
                        P::S(s) => s as &(dyn ToSql + Sync),
                        P::Now => &self.now as &(dyn ToSql + Sync),
                    })
                    .collect();
                let rows = client.query(sql.as_ref(), &args).await?;
                rows.into_iter().map(|mut r| f(&mut r)).collect()
            }
            Conn::My(conn) => {
                let args: Vec<Value> = params
                    .iter()
                    .map(|p| match p {
                        P::I(v) => Value::Int(*v),
                        P::S(s) => Value::Bytes(s.as_bytes().to_vec()),
                        P::Now => Value::Bytes(NOW.as_bytes().to_vec()),
                    })
                    .collect();
                let rows: Vec<mysql_async::Row> = conn.exec(sql.as_ref(), args).await?;
                rows.into_iter().map(|mut r| f(&mut r)).collect()
            }
        }
    }

    async fn handle(&self, req: Request<Incoming>) -> Result<Response<Full<Bytes>>> {
        let header = req.headers().get(AUTHORIZATION).map(|v| v.as_bytes()).unwrap_or(b"");
        let token = if header.len() > 7 { &header[7..] } else { b"" };
        let hash = hex::encode(Sha256::digest(token));
        let mut c = self.conn().await?;
        let mut users = self
            .query(
                &mut c,
                "SELECT u.id, u.username FROM blog_session s JOIN symfony_demo_user u ON u.id = s.user_id WHERE s.token_hash = ? AND s.expires_at > ?",
                &[P::S(&hash), P::Now],
                |r| Ok(User { id: r.int(0)?, username: r.str(1)? }),
            )
            .await?;
        if !header.starts_with(b"Bearer ") || users.is_empty() {
            return reply(401, &ErrorBody { error: "unauthorized" });
        }
        let user = users.swap_remove(0);
        if let Some((client, uri)) = &self.upstream {
            drop(c);
            let resp = client.get(uri.clone()).await?;
            let body = resp.into_body().collect().await?.to_bytes();
            if body.as_ref() != br#"{"ok":true}"# {
                return Err(format!("upstream: {}", String::from_utf8_lossy(&body)).into());
            }
            c = self.conn().await?;
        }

        let path = req.uri().path();
        if path == "/posts" {
            return self.list_posts(&mut c, user, req.uri().query()).await;
        }
        if let Some(rest) = path.strip_prefix("/posts/") {
            // Go's "/posts/{slug}" matches one non-empty segment and unescapes it.
            if !rest.is_empty() && !rest.contains('/') {
                if let Some(slug) = percent_decode(rest, false) {
                    return self.show_post(&mut c, user, &slug).await;
                }
            }
        }
        reply(404, &ErrorBody { error: "not found" })
    }

    async fn list_posts(&self, c: &mut Conn, user: User, query: Option<&str>) -> Result<Response<Full<Bytes>>> {
        let mut page: i64 = 1;
        if let Some(v) = query_get(query.unwrap_or(""), "page") {
            if !v.is_empty() {
                page = v.parse().unwrap_or(0); // strconv.Atoi with the error ignored
            }
        }
        let sql = format!(
            "SELECT p.id, p.title, p.slug, p.summary, {}, u.id, u.full_name FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id ORDER BY p.published_at DESC LIMIT 20 OFFSET ?",
            self.at("p.published_at")
        );
        let mut posts = self
            .query(c, &sql, &[P::I(page.wrapping_sub(1).wrapping_mul(20))], |r| {
                Ok(ListPost {
                    id: r.int(0)?,
                    title: r.str(1)?,
                    slug: r.str(2)?,
                    summary: r.str(3)?,
                    published_at: atom(&r.str(4)?),
                    author: Author { id: r.int(5)?, name: r.str(6)? },
                    tags: Vec::new(),
                    comment_count: 0,
                })
            })
            .await?;
        if !posts.is_empty() {
            let ids: Vec<P> = posts.iter().map(|p| P::I(p.id)).collect();
            let ph = placeholders(ids.len());
            let index = |posts: &[ListPost], id: i64| posts.iter().position(|p| p.id == id).ok_or("unknown post id");
            let sql = format!(
                "SELECT pt.post_id, t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id WHERE pt.post_id IN ({ph}) ORDER BY pt.post_id, t.name"
            );
            for (id, name) in self.query(c, &sql, &ids, |r| Ok((r.int(0)?, r.str(1)?))).await? {
                let i = index(&posts, id)?;
                posts[i].tags.push(name);
            }
            let sql = format!("SELECT post_id, COUNT(*) FROM symfony_demo_comment WHERE post_id IN ({ph}) GROUP BY post_id");
            for (id, n) in self.query(c, &sql, &ids, |r| Ok((r.int(0)?, r.int(1)?))).await? {
                let i = index(&posts, id)?;
                posts[i].comment_count = n;
            }
        }
        reply(200, &ListResponse { user, page, posts })
    }

    async fn show_post(&self, c: &mut Conn, user: User, slug: &str) -> Result<Response<Full<Bytes>>> {
        let sql = format!(
            "SELECT p.id, p.title, p.slug, p.summary, p.content, {}, u.id, u.full_name FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id WHERE p.slug = ?",
            self.at("p.published_at")
        );
        let mut found = self
            .query(c, &sql, &[P::S(slug)], |r| {
                Ok(Post {
                    id: r.int(0)?,
                    title: r.str(1)?,
                    slug: r.str(2)?,
                    summary: r.str(3)?,
                    content: r.str(4)?,
                    published_at: atom(&r.str(5)?),
                    author: Author { id: r.int(6)?, name: r.str(7)? },
                    tags: Vec::new(),
                    comments: Vec::new(),
                })
            })
            .await?;
        if found.is_empty() {
            return reply(404, &ErrorBody { error: "not found" });
        }
        let mut post = found.swap_remove(0);
        post.tags = self
            .query(
                c,
                "SELECT t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id WHERE pt.post_id = ? ORDER BY t.name",
                &[P::I(post.id)],
                |r| r.str(0),
            )
            .await?;
        let sql = format!(
            "SELECT c.id, u.full_name, c.content, {} FROM symfony_demo_comment c JOIN symfony_demo_user u ON u.id = c.author_id WHERE c.post_id = ? ORDER BY c.published_at, c.id",
            self.at("c.published_at")
        );
        post.comments = self
            .query(c, &sql, &[P::I(post.id)], |r| {
                Ok(Comment { id: r.int(0)?, author: r.str(1)?, content: r.str(2)?, published_at: atom(&r.str(3)?) })
            })
            .await?;
        reply(200, &PostResponse { user, post })
    }
}

fn atom(s: &str) -> String {
    format!("{}T{}+00:00", &s[..10], &s[11..])
}

fn placeholders(n: usize) -> String {
    vec!["?"; n].join(", ")
}

fn reply(status: u16, v: &impl Serialize) -> Result<Response<Full<Bytes>>> {
    let body = serde_json::to_vec(v)?;
    Ok(Response::builder()
        .status(status)
        .header(CONTENT_TYPE, HeaderValue::from_static("application/json"))
        .body(Full::new(Bytes::from(body)))?)
}

fn hex_val(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

/// Percent-decoding (and '+' as space in a query string); None on a bad escape or invalid UTF-8.
fn percent_decode(s: &str, plus: bool) -> Option<Cow<'_, str>> {
    if !s.bytes().any(|c| c == b'%' || (plus && c == b'+')) {
        return Some(Cow::Borrowed(s));
    }
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' => {
                let hi = hex_val(*b.get(i + 1)?)?;
                let lo = hex_val(*b.get(i + 2)?)?;
                out.push(hi << 4 | lo);
                i += 3;
            }
            b'+' if plus => {
                out.push(b' ');
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok().map(Cow::Owned)
}

/// First value of `key` in a query string, like Go's url.Values.Get.
fn query_get<'a>(query: &'a str, key: &str) -> Option<Cow<'a, str>> {
    for pair in query.split('&') {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        if percent_decode(k, true).as_deref() == Some(key) {
            return percent_decode(v, true);
        }
    }
    None
}

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_default()
}

#[tokio::main]
async fn main() -> Result<()> {
    let size: usize = env("BLOG_POOL").parse().ok().filter(|&n| n > 0).unwrap_or(24);
    let dsn = env("BLOG_DSN");
    let db = match env("BLOG_DRIVER").as_str() {
        "pg" | "pgx" | "postgres" => {
            let cfg: tokio_postgres::Config = dsn.parse()?;
            let mgr = Manager::from_config(cfg, NoTls, ManagerConfig { recycling_method: RecyclingMethod::Fast });
            let pool = PgPool::builder(mgr).max_size(size).build()?;
            drop(pool.get().await?); // ping
            Db::Pg(pool)
        }
        "mysql" => {
            // Pool of `size`, default reset of the session on return to the pool.
            let pool_opts = PoolOpts::default().with_constraints(PoolConstraints::new(size, size).ok_or("bad pool size")?);
            let opts = OptsBuilder::from_opts(Opts::from_url(&dsn)?).pool_opts(pool_opts);
            let pool = mysql_async::Pool::new(opts);
            pool.get_conn().await?.ping().await?;
            Db::My(pool)
        }
        d => return Err(format!("BLOG_DRIVER must be pg or mysql, got {d:?}").into()),
    };
    let upstream = match env("BLOG_UPSTREAM") {
        u if u.is_empty() => None,
        u => {
            let mut conn = HttpConnector::new();
            conn.set_nodelay(true);
            Some((Client::builder(TokioExecutor::new()).build(conn), u.parse::<Uri>()?))
        }
    };
    let app = Arc::new(App { db, now: UNIX_EPOCH + Duration::from_secs(NOW_UNIX), upstream });

    let addr = env("BLOG_ADDR");
    let listener = TcpListener::bind(&addr).await?;
    println!("listening {addr}");
    loop {
        let (stream, _) = match listener.accept().await {
            Ok(s) => s,
            Err(e) => {
                eprintln!("accept: {e}");
                continue;
            }
        };
        let _ = stream.set_nodelay(true);
        let app = app.clone();
        tokio::spawn(async move {
            let svc = service_fn(move |req| {
                let app = app.clone();
                async move {
                    Ok::<_, Infallible>(match app.handle(req).await {
                        Ok(r) => r,
                        Err(e) => {
                            eprintln!("error: {e:?}");
                            let mut r = Response::new(Full::new(Bytes::new()));
                            *r.status_mut() = StatusCode::INTERNAL_SERVER_ERROR;
                            r
                        }
                    })
                }
            });
            let _ = http1::Builder::new().serve_connection(TokioIo::new(stream), svc).await;
        });
    }
}
