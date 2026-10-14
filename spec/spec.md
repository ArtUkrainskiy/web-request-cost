# Blog API: the task every implementation does

One HTTP JSON API over the Symfony Demo data ×100 (3,000 posts of ~1.9 KB, 15,000 comments, 9 tags, 3 authors) in PostgreSQL 17 or MySQL 8.4, plus 1,000 readers with session tokens. Every implementation runs the same SQL in the same order and returns the same responses.

## Authentication (every request)
- Header `Authorization: Bearer <token>`. Tokens are `tok-<n>` for n = 1..1000.
- The server computes `sha256(token)` as lowercase hex and runs
  `SELECT u.id, u.username FROM blog_session s JOIN symfony_demo_user u ON u.id = s.user_id WHERE s.token_hash = ? AND s.expires_at > ?`
  with the second parameter `'2026-10-13 00:00:00'` (a fixed "now", so runs are reproducible).
- No row → `401` with body `{"error":"unauthorized"}`.

## GET /posts?page=N
N = 1..150, 20 posts per page, newest first.
1. `SELECT p.id, p.title, p.slug, p.summary, <published_at as text>, u.id, u.full_name FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id ORDER BY p.published_at DESC LIMIT 20 OFFSET ?`
2. `SELECT pt.post_id, t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id WHERE pt.post_id IN (?, … 20 placeholders) ORDER BY pt.post_id, t.name`
3. `SELECT post_id, COUNT(*) FROM symfony_demo_comment WHERE post_id IN (?, …) GROUP BY post_id`

Response:
`{"user":{"id":…,"username":…},"page":N,"posts":[{"id","title","slug","summary","published_at","author":{"id","name"},"tags":[…],"comment_count":…}, …]}`

## GET /posts/{slug}
1. `SELECT p.id, p.title, p.slug, p.summary, p.content, <published_at as text>, u.id, u.full_name FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id WHERE p.slug = ?` — no row → `404` `{"error":"not found"}`.
2. Tags of the post: `… WHERE pt.post_id = ? ORDER BY t.name`.
3. `SELECT c.id, u.full_name, c.content, <published_at as text> FROM symfony_demo_comment c JOIN symfony_demo_user u ON u.id = c.author_id WHERE c.post_id = ? ORDER BY c.published_at, c.id`

Response:
`{"user":{…},"post":{"id","title","slug","summary","content","published_at","author":{"id","name"},"tags":[…],"comments":[{"id","author","content","published_at"}, …]}}`

## Encoding rules
- `<published_at as text>`: PostgreSQL `to_char(x, 'YYYY-MM-DD HH24:MI:SS')`, MySQL `DATE_FORMAT(x, '%Y-%m-%d %H:%i:%s')`; the server turns `YYYY-MM-DD HH:MM:SS` into `YYYY-MM-DDTHH:MM:SS+00:00` by string operations.
- JSON as each encoder writes it by default (escaping of `/` and non-ASCII and whitespace differ between languages), keys in the order above, integers as numbers.
- `Content-Type: application/json`, no trailing newline.

## Data
- `data/blog-pg.sql.gz` and `data/blog-my.sql.gz`: dumps for PostgreSQL 17 and MySQL 8.4 — the Symfony Demo tables repeated ×100 plus `blog_session`. `seed.php` shows how the 1,000 readers, their sessions (`sha256("tok-<n>")`, valid until 2027-01-01) and the indexes (`post_published`, `post_slug`, `comment_post`) were added. `harness/stack/db.sh` creates the database containers from the dumps. The posts, comments, tags and authors come from the Symfony Demo application (https://github.com/symfony/demo, MIT licence, © Fabien Potencier).

## Request lists
- `requests/requests.txt` — the response check: pages 1..150 and posts with equal probability, seed 1.
- `requests/requests-zipf.txt` — the load: 80% `/posts?page=N` with P(N) ∝ 1/N, 20% `/posts/{slug}` with P ∝ 1/recency rank, token uniform over 1..1000, 1% unknown token (401), seed 1.
- One `<path> <token>` per line; `requests/requests.mjs` generates both from `requests/slugs.txt` and `requests/slugs-recent.txt`.

## Equivalence
The harness compares responses by status, media type and JSON content with object keys sorted (`harness/load/verify.mjs`, `canon` mode), so escaping of `/` and non-ASCII characters and the key order are not part of the check; the bodies above are what the implementations return.

Both databases give the same responses. Reference hashes: `4cb01d080299bb64ea71f0564c9fa067aedb24ca576a85d17f53c19ab1c7f09d` for the first 2,000 requests of `requests.txt`, `75cf48406c2e7a408902b35aef4163b43e6e7509d6309b2866fe8b5523f2c57b` for the first 200 (both `canon`); `harness/README.md` lists where each is used.
