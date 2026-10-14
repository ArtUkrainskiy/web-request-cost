// Blog API from spec/spec.md: net/http with Go 1.22 routing; PostgreSQL through the
// native pgxpool, MySQL through database/sql with go-sql-driver. Pool of BLOG_POOL connections.
// Driver defaults: pgx caches prepared statements per connection; go-sql-driver prepares, executes
// and closes every statement.
//
//	BLOG_DRIVER=pgx|mysql BLOG_DSN=... BLOG_POOL=24 BLOG_ADDR=127.0.0.1:8081 ./blog
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"

	_ "github.com/go-sql-driver/mysql"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const now = "2026-10-13 00:00:00"

type User struct {
	ID       int64  `json:"id"`
	Username string `json:"username"`
}

type Author struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

type ListPost struct {
	ID           int64    `json:"id"`
	Title        string   `json:"title"`
	Slug         string   `json:"slug"`
	Summary      string   `json:"summary"`
	PublishedAt  string   `json:"published_at"`
	Author       Author   `json:"author"`
	Tags         []string `json:"tags"`
	CommentCount int64    `json:"comment_count"`
}

type ListResponse struct {
	User  User       `json:"user"`
	Page  int        `json:"page"`
	Posts []ListPost `json:"posts"`
}

type Comment struct {
	ID          int64  `json:"id"`
	Author      string `json:"author"`
	Content     string `json:"content"`
	PublishedAt string `json:"published_at"`
}

type Post struct {
	ID          int64     `json:"id"`
	Title       string    `json:"title"`
	Slug        string    `json:"slug"`
	Summary     string    `json:"summary"`
	Content     string    `json:"content"`
	PublishedAt string    `json:"published_at"`
	Author      Author    `json:"author"`
	Tags        []string  `json:"tags"`
	Comments    []Comment `json:"comments"`
}

type PostResponse struct {
	User User `json:"user"`
	Post Post `json:"post"`
}

type Error struct {
	Error string `json:"error"`
}

// rows and the two query functions hide the difference between pgx and database/sql.
type rows interface {
	Next() bool
	Scan(dest ...any) error
	Err() error
}

var (
	upstream       = os.Getenv("BLOG_UPSTREAM")
	upstreamClient = &http.Client{Transport: &http.Transport{MaxIdleConns: 0, MaxIdleConnsPerHost: 100000}}
	pg             bool
	pool           *pgxpool.Pool
	db             *sql.DB
	errNoRow       = errors.New("no rows")
)

// reqConn holds the connection of a request: its statements run on it, and it goes back to the pool
// while the upstream is awaited.
type reqConn struct {
	pg *pgxpool.Conn
	my *sql.Conn
}

type connKey struct{}

func acquire(ctx context.Context) *reqConn {
	var err error
	c := &reqConn{}
	if pg {
		c.pg, err = pool.Acquire(ctx)
	} else {
		c.my, err = db.Conn(ctx)
	}
	must(err)
	return c
}

func (c *reqConn) release() {
	if c.pg != nil {
		c.pg.Release()
	}
	if c.my != nil {
		c.my.Close()
	}
	*c = reqConn{}
}

func conn(ctx context.Context) *reqConn { return ctx.Value(connKey{}).(*reqConn) }

func query(ctx context.Context, q string, args ...any) (rows, func()) {
	if pg {
		r, err := conn(ctx).pg.Query(ctx, q, args...)
		must(err)
		return r, r.Close
	}
	r, err := conn(ctx).my.QueryContext(ctx, q, args...)
	must(err)
	return r, func() { r.Close() }
}

func queryRow(ctx context.Context, q string, args []any, dest ...any) error {
	var err error
	if pg {
		err = conn(ctx).pg.QueryRow(ctx, q, args...).Scan(dest...)
		if errors.Is(err, pgx.ErrNoRows) {
			return errNoRow
		}
	} else {
		err = conn(ctx).my.QueryRowContext(ctx, q, args...).Scan(dest...)
		if errors.Is(err, sql.ErrNoRows) {
			return errNoRow
		}
	}
	return err
}

func atom(s string) string { return s[:10] + "T" + s[11:] + "+00:00" }

func at(col string) string {
	if pg {
		return "to_char(" + col + ", 'YYYY-MM-DD HH24:MI:SS')"
	}
	return "DATE_FORMAT(" + col + ", '%Y-%m-%d %H:%i:%s')"
}

// q turns ? placeholders into $1, $2, … for PostgreSQL.
func q(s string) string {
	if !pg {
		return s
	}
	var b strings.Builder
	n := 0
	for _, c := range s {
		if c == '?' {
			n++
			b.WriteString("$" + strconv.Itoa(n))
			continue
		}
		b.WriteRune(c)
	}
	return b.String()
}

const pageSize = 20

// sqlStmt holds the SQL texts, built once for the driver in use (IN lists for 1..pageSize ids).
var sqlStmt struct {
	auth, list, show, tagsOf, comments string
	tagsIn, countsIn                   [pageSize + 1]string
}

func buildSQL() {
	sqlStmt.auth = q("SELECT u.id, u.username FROM blog_session s JOIN symfony_demo_user u ON u.id = s.user_id WHERE s.token_hash = ? AND s.expires_at > ?")
	sqlStmt.list = q("SELECT p.id, p.title, p.slug, p.summary, " + at("p.published_at") + ", u.id, u.full_name FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id ORDER BY p.published_at DESC LIMIT 20 OFFSET ?")
	sqlStmt.show = q("SELECT p.id, p.title, p.slug, p.summary, p.content, " + at("p.published_at") + ", u.id, u.full_name FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id WHERE p.slug = ?")
	sqlStmt.tagsOf = q("SELECT t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id WHERE pt.post_id = ? ORDER BY t.name")
	sqlStmt.comments = q("SELECT c.id, u.full_name, c.content, " + at("c.published_at") + " FROM symfony_demo_comment c JOIN symfony_demo_user u ON u.id = c.author_id WHERE c.post_id = ? ORDER BY c.published_at, c.id")
	for n := 1; n <= pageSize; n++ {
		sqlStmt.tagsIn[n] = q("SELECT pt.post_id, t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id WHERE pt.post_id IN (" + placeholders(n) + ") ORDER BY pt.post_id, t.name")
		sqlStmt.countsIn[n] = q("SELECT post_id, COUNT(*) FROM symfony_demo_comment WHERE post_id IN (" + placeholders(n) + ") GROUP BY post_id")
	}
}

func placeholders(n int) string {
	return strings.TrimSuffix(strings.Repeat("?, ", n), ", ")
}

func reply(w http.ResponseWriter, status int, v any) {
	var buf bytes.Buffer
	must(json.NewEncoder(&buf).Encode(v))
	body := bytes.TrimSuffix(buf.Bytes(), []byte("\n"))
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	w.Write(body)
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

type ctxKey struct{}

// recoverer turns a failed query into 500; a request cancelled by its client ends silently.
func recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				if r.Context().Err() != nil {
					return
				}
				log.Printf("error: %v", v)
				w.WriteHeader(500)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// auth runs for every request, before routing, as in the spec.
func auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		token := ""
		if len(header) > 7 {
			token = header[7:]
		}
		sum := sha256.Sum256([]byte(token))
		ctx := r.Context()
		c := acquire(ctx)
		defer c.release()
		ctx = context.WithValue(ctx, connKey{}, c)
		var user User
		err := queryRow(ctx, sqlStmt.auth,
			[]any{hex.EncodeToString(sum[:]), now}, &user.ID, &user.Username)
		if !strings.HasPrefix(header, "Bearer ") || err == errNoRow {
			reply(w, 401, Error{"unauthorized"})
			return
		}
		must(err)
		if upstream != "" {
			c.release()
			req, err := http.NewRequestWithContext(ctx, "GET", upstream, nil)
			must(err)
			resp, err := upstreamClient.Do(req)
			must(err)
			body, err := io.ReadAll(resp.Body)
			resp.Body.Close()
			must(err)
			if string(body) != `{"ok":true}` {
				panic("upstream: " + string(body))
			}
			*c = *acquire(ctx)
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(ctx, ctxKey{}, user)))
	})
}

func listPosts(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	user := ctx.Value(ctxKey{}).(User)
	page := 1
	if v := r.URL.Query().Get("page"); v != "" {
		page, _ = strconv.Atoi(v)
	}
	rs, done := query(ctx, sqlStmt.list, (page-1)*20)
	posts := []ListPost{}
	index := map[int64]int{}
	for rs.Next() {
		var p ListPost
		must(rs.Scan(&p.ID, &p.Title, &p.Slug, &p.Summary, &p.PublishedAt, &p.Author.ID, &p.Author.Name))
		p.PublishedAt = atom(p.PublishedAt)
		p.Tags = []string{}
		index[p.ID] = len(posts)
		posts = append(posts, p)
	}
	must(rs.Err())
	done()
	if len(posts) > 0 {
		ids := make([]any, len(posts))
		for i, p := range posts {
			ids[i] = p.ID
		}
		rs, done = query(ctx, sqlStmt.tagsIn[len(ids)], ids...)
		for rs.Next() {
			var id int64
			var name string
			must(rs.Scan(&id, &name))
			p := &posts[index[id]]
			p.Tags = append(p.Tags, name)
		}
		must(rs.Err())
		done()
		rs, done = query(ctx, sqlStmt.countsIn[len(ids)], ids...)
		for rs.Next() {
			var id, n int64
			must(rs.Scan(&id, &n))
			posts[index[id]].CommentCount = n
		}
		must(rs.Err())
		done()
	}
	reply(w, 200, ListResponse{user, page, posts})
}

func showPost(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	user := ctx.Value(ctxKey{}).(User)
	var p Post
	err := queryRow(ctx, sqlStmt.show,
		[]any{r.PathValue("slug")}, &p.ID, &p.Title, &p.Slug, &p.Summary, &p.Content, &p.PublishedAt, &p.Author.ID, &p.Author.Name)
	if err == errNoRow {
		reply(w, 404, Error{"not found"})
		return
	}
	must(err)
	p.PublishedAt = atom(p.PublishedAt)
	p.Tags = []string{}
	p.Comments = []Comment{}
	rs, done := query(ctx, sqlStmt.tagsOf, p.ID)
	for rs.Next() {
		var name string
		must(rs.Scan(&name))
		p.Tags = append(p.Tags, name)
	}
	must(rs.Err())
	done()
	rs, done = query(ctx, sqlStmt.comments, p.ID)
	for rs.Next() {
		var c Comment
		must(rs.Scan(&c.ID, &c.Author, &c.Content, &c.PublishedAt))
		c.PublishedAt = atom(c.PublishedAt)
		p.Comments = append(p.Comments, c)
	}
	must(rs.Err())
	done()
	reply(w, 200, PostResponse{user, p})
}

func main() {
	pg = os.Getenv("BLOG_DRIVER") == "pgx"
	buildSQL()
	size, _ := strconv.Atoi(os.Getenv("BLOG_POOL"))
	if size <= 0 {
		size = 24
	}
	if pg {
		cfg, err := pgxpool.ParseConfig(os.Getenv("BLOG_DSN"))
		must(err)
		cfg.MaxConns = int32(size)
		pool, err = pgxpool.NewWithConfig(context.Background(), cfg)
		must(err)
		must(pool.Ping(context.Background()))
	} else {
		var err error
		db, err = sql.Open("mysql", os.Getenv("BLOG_DSN"))
		must(err)
		db.SetMaxOpenConns(size)
		db.SetMaxIdleConns(size)
		must(db.Ping())
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /posts", listPosts)
	mux.HandleFunc("GET /posts/{slug}", showPost)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { reply(w, 404, Error{"not found"}) })
	addr := os.Getenv("BLOG_ADDR")
	fmt.Println("listening", addr)
	log.Fatal(http.ListenAndServe(addr, recoverer(auth(mux))))
}
