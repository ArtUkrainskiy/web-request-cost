# Blog API from spec/spec.md as a raw ASGI app (no framework, no ORM): asyncpg for
# PostgreSQL, asyncmy for MySQL, a pool of BLOG_POOL connections per process, the json module for the
# body, aiohttp for the optional upstream call. Served by server.py (uvicorn, uvloop, httptools).
#   BLOG_DRIVER=pg|mysql BLOG_DSN=... BLOG_POOL=3 [BLOG_UPSTREAM=url]
import datetime
import hashlib
import json
import os
import sys
import traceback
from urllib.parse import parse_qsl, urlsplit


DRIVER = os.environ.get("BLOG_DRIVER", "pg")
DSN = os.environ["BLOG_DSN"]
POOL = int(os.environ.get("BLOG_POOL") or 3)
UPSTREAM = os.environ.get("BLOG_UPSTREAM") or None
IS_PG = DRIVER == "pg"

# The fixed "now": asyncpg binds typed parameters (a timestamp needs a datetime); asyncmy
# interpolates a quoted literal, so the string goes as is.
NOW = datetime.datetime(2026, 10, 13) if IS_PG else "2026-10-13 00:00:00"


def sql(s):
    """? placeholders → $1, $2, … (asyncpg) or %s (asyncmy, which also needs % doubled)."""
    if not IS_PG:
        return s.replace("%", "%%").replace("?", "%s")
    out, n = [], 0
    for part in s.split("?"):
        if out:
            n += 1
            out.append(f"${n}")
        out.append(part)
    return "".join(out)


def at(col):
    return f"to_char({col}, 'YYYY-MM-DD HH24:MI:SS')" if IS_PG else f"DATE_FORMAT({col}, '%Y-%m-%d %H:%i:%s')"


def atom(s):
    return s[:10] + "T" + s[11:] + "+00:00"


def placeholders(n):
    return ", ".join("?" * n)


SQL_AUTH = sql("SELECT u.id, u.username FROM blog_session s JOIN symfony_demo_user u ON u.id = s.user_id WHERE s.token_hash = ? AND s.expires_at > ?")
SQL_LIST = sql(f"SELECT p.id, p.title, p.slug, p.summary, {at('p.published_at')}, u.id, u.full_name FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id ORDER BY p.published_at DESC LIMIT 20 OFFSET ?")
SQL_POST = sql(f"SELECT p.id, p.title, p.slug, p.summary, p.content, {at('p.published_at')}, u.id, u.full_name FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id WHERE p.slug = ?")
SQL_POST_TAGS = sql("SELECT t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id WHERE pt.post_id = ? ORDER BY t.name")
SQL_COMMENTS = sql(f"SELECT c.id, u.full_name, c.content, {at('c.published_at')} FROM symfony_demo_comment c JOIN symfony_demo_user u ON u.id = c.author_id WHERE c.post_id = ? ORDER BY c.published_at, c.id")
SQL_TAGS_IN = {}
SQL_COUNTS_IN = {}


def sql_tags_in(n):
    s = SQL_TAGS_IN.get(n)
    if s is None:
        s = SQL_TAGS_IN[n] = sql(f"SELECT pt.post_id, t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id WHERE pt.post_id IN ({placeholders(n)}) ORDER BY pt.post_id, t.name")
    return s


def sql_counts_in(n):
    s = SQL_COUNTS_IN.get(n)
    if s is None:
        s = SQL_COUNTS_IN[n] = sql(f"SELECT post_id, COUNT(*) FROM symfony_demo_comment WHERE post_id IN ({placeholders(n)}) GROUP BY post_id")
    return s


pool = None
session = None


async def query(conn, q, *args):
    """Runs one statement on conn; rows as tuples."""
    if IS_PG:
        return await conn.fetch(q, *args)
    async with conn.cursor() as cur:
        await cur.execute(q, args)
        return await cur.fetchall()


async def startup():
    global pool, session
    if IS_PG:
        import asyncpg

        # Lazy like pg.Pool and pgxpool: connections open on demand, up to POOL.
        pool = await asyncpg.create_pool(DSN, min_size=0, max_size=POOL)
    else:
        import asyncmy

        u = urlsplit(DSN)
        pool = await asyncmy.create_pool(
            host=u.hostname, port=u.port or 3306, user=u.username, password=u.password or "",
            db=u.path.lstrip("/"), charset="utf8mb4", autocommit=True, minsize=0, maxsize=POOL,
        )
    if UPSTREAM:
        import aiohttp

        # One keep-alive session per process, no cap on connections per host.
        session = aiohttp.ClientSession(connector=aiohttp.TCPConnector(limit=0))


async def shutdown():
    if session is not None:
        await session.close()
    if pool is not None:
        if IS_PG:
            await pool.close()
        else:
            pool.close()
            await pool.wait_closed()


def dumps(v):
    return json.dumps(v).encode()


UNAUTHORIZED = dumps({"error": "unauthorized"})
NOT_FOUND = dumps({"error": "not found"})


# The statements of a request share one connection, returned to the pool while the upstream is awaited.
async def handle(path, query_string, auth):
    token_hash = hashlib.sha256(auth[7:].encode()).hexdigest()
    async with pool.acquire() as conn:
        u = await query(conn, SQL_AUTH, token_hash, NOW)
        if not auth.startswith("Bearer ") or not u:
            return 401, UNAUTHORIZED
        user = {"id": u[0][0], "username": u[0][1]}
        if not UPSTREAM:
            return await respond(conn, path, query_string, user)
    async with session.get(UPSTREAM) as r:
        reply = await r.read()
    if reply != b'{"ok":true}':
        raise RuntimeError(f"upstream: {reply!r}")
    async with pool.acquire() as conn:
        return await respond(conn, path, query_string, user)


async def respond(conn, path, query_string, user):
    if path == "/posts":
        page = 1
        for k, v in parse_qsl(query_string):
            if k == "page":
                try:
                    page = int(v)
                except ValueError:
                    page = 0
                break
        posts = []
        index = {}
        for r in await query(conn, SQL_LIST, (page - 1) * 20):
            p = {"id": r[0], "title": r[1], "slug": r[2], "summary": r[3], "published_at": atom(r[4]),
                 "author": {"id": r[5], "name": r[6]}, "tags": [], "comment_count": 0}
            index[r[0]] = p
            posts.append(p)
        if posts:
            ids = list(index)
            for pid, name in await query(conn, sql_tags_in(len(ids)), *ids):
                index[pid]["tags"].append(name)
            for pid, n in await query(conn, sql_counts_in(len(ids)), *ids):
                index[pid]["comment_count"] = n
        return 200, dumps({"user": user, "page": page, "posts": posts})

    if path.startswith("/posts/"):
        rows = await query(conn, SQL_POST, path[7:])
        if not rows:
            return 404, NOT_FOUND
        r = rows[0]
        post = {"id": r[0], "title": r[1], "slug": r[2], "summary": r[3], "content": r[4],
                "published_at": atom(r[5]), "author": {"id": r[6], "name": r[7]}, "tags": [], "comments": []}
        post["tags"] = [t[0] for t in await query(conn, SQL_POST_TAGS, r[0])]
        post["comments"] = [{"id": c[0], "author": c[1], "content": c[2], "published_at": atom(c[3])}
                            for c in await query(conn, SQL_COMMENTS, r[0])]
        return 200, dumps({"user": user, "post": post})

    return 404, NOT_FOUND


async def app(scope, receive, send):
    if scope["type"] == "http":
        auth = ""
        for k, v in scope["headers"]:
            if k == b"authorization":
                auth = v.decode("latin-1")
                break
        try:
            # scope["path"] is already percent-decoded by the server.
            status, body = await handle(scope["path"], scope["query_string"].decode("latin-1"), auth)
        except Exception:
            traceback.print_exc(file=sys.stderr)
            status, body = 500, b""
        await send({"type": "http.response.start", "status": status,
                    "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())]})
        await send({"type": "http.response.body", "body": body})
    elif scope["type"] == "lifespan":
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                try:
                    await startup()
                except Exception as e:
                    await send({"type": "lifespan.startup.failed", "message": repr(e)})
                    return
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                await shutdown()
                await send({"type": "lifespan.shutdown.complete"})
                return
