// Blog API from spec/spec.md: ASP.NET Core minimal APIs on Kestrel, ADO.NET without an ORM.
// PostgreSQL through NpgsqlDataSource, MySQL through MySqlDataSource; each driver pools its own
// connections (Maximum Pool Size = BLOG_POOL). JSON through System.Text.Json with the minimal-API defaults.
//
//   BLOG_DRIVER=pgsql|mysql BLOG_DSN='Host=...' BLOG_POOL=24 BLOG_ADDR=127.0.0.1:8100 dotnet Blog.dll
using System.Data.Common;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using MySqlConnector;
using Npgsql;
using NpgsqlTypes;

const string Now = "2026-10-13 00:00:00";

var pg = Environment.GetEnvironmentVariable("BLOG_DRIVER") is "pgsql" or "pgx" or "pg";
var dsn = Environment.GetEnvironmentVariable("BLOG_DSN") ?? throw new InvalidOperationException("BLOG_DSN");
var poolSize = int.TryParse(Environment.GetEnvironmentVariable("BLOG_POOL"), out var n) && n > 0 ? n : 24;
var upstream = Environment.GetEnvironmentVariable("BLOG_UPSTREAM") ?? "";

DbDataSource ds;
if (pg) {
	var b = new NpgsqlDataSourceBuilder(dsn);
	b.ConnectionStringBuilder.MaxPoolSize = poolSize;
	ds = b.Build();
} else {
	var b = new MySqlDataSourceBuilder(dsn);
	b.ConnectionStringBuilder.MaximumPoolSize = (uint)poolSize;
	ds = b.Build();
}
await using (var c = await ds.OpenConnectionAsync()) { } // fail fast, like Go's Ping

// The minimal-API defaults (JsonSerializerDefaults.Web) with the snake_case names of the spec.
var json = new JsonSerializerOptions(JsonSerializerDefaults.Web) { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };
var unauthorized = new Error("unauthorized");
var notFound = new Error("not found");

string At(string col) => pg ? $"to_char({col}, 'YYYY-MM-DD HH24:MI:SS')" : $"DATE_FORMAT({col}, '%Y-%m-%d %H:%i:%s')";

// Q turns ? placeholders into $1, $2, … for PostgreSQL.
string Q(string s) {
	if (!pg) return s;
	var sb = new StringBuilder(s.Length + 16);
	var i = 0;
	foreach (var ch in s) {
		if (ch == '?') sb.Append('$').Append(++i);
		else sb.Append(ch);
	}
	return sb.ToString();
}

string Placeholders(int count) => string.Join(", ", Enumerable.Repeat("?", count));

var authSql = Q("SELECT u.id, u.username FROM blog_session s JOIN symfony_demo_user u ON u.id = s.user_id WHERE s.token_hash = ? AND s.expires_at > ?");
var listSql = Q($"SELECT p.id, p.title, p.slug, p.summary, {At("p.published_at")}, u.id, u.full_name FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id ORDER BY p.published_at DESC LIMIT 20 OFFSET ?");
var postSql = Q($"SELECT p.id, p.title, p.slug, p.summary, p.content, {At("p.published_at")}, u.id, u.full_name FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id WHERE p.slug = ?");
var postTagsSql = Q("SELECT t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id WHERE pt.post_id = ? ORDER BY t.name");
var commentsSql = Q($"SELECT c.id, u.full_name, c.content, {At("c.published_at")} FROM symfony_demo_comment c JOIN symfony_demo_user u ON u.id = c.author_id WHERE c.post_id = ? ORDER BY c.published_at, c.id");

DbCommand Command(DbConnection conn, string sql, params object[] args) {
	var cmd = conn.CreateCommand();
	cmd.CommandText = sql;
	foreach (var a in args) {
		DbParameter p;
		// Strings go to PostgreSQL untyped and the server infers the type (char(64), timestamp),
		// as pgx, node-postgres and PDO do; Npgsql would otherwise send them as text.
		if (pg && a is string) p = new NpgsqlParameter { Value = a, NpgsqlDbType = NpgsqlDbType.Unknown };
		else {
			p = cmd.CreateParameter();
			p.Value = a;
		}
		cmd.Parameters.Add(p);
	}
	return cmd;
}

Task<DbDataReader> Read(DbCommand cmd, CancellationToken ct) => cmd.ExecuteReaderAsync(ct);

// Content root = the publish directory, so appsettings.json is found whatever the working directory.
var builder = WebApplication.CreateBuilder(new WebApplicationOptions { Args = args, ContentRootPath = AppContext.BaseDirectory });
builder.WebHost.UseUrls("http://" + (Environment.GetEnvironmentVariable("BLOG_ADDR") ?? "127.0.0.1:8100"));
builder.Services.AddHttpClient("upstream");
var app = builder.Build();
var httpClients = app.Services.GetRequiredService<IHttpClientFactory>();

IResult Reply<T>(T value, int status) => TypedResults.Json(value, json, "application/json", status);

// Authentication runs for every request, before routing, as in the spec. The statements of a request
// share one connection (ctx.Items), returned to the pool while the upstream is awaited.
app.Use(async (HttpContext ctx, RequestDelegate next) => {
	var auth = ctx.Request.Headers.Authorization;
	var header = auth.Count > 0 ? auth[0] ?? "" : "";
	var token = header.Length > 7 ? header[7..] : "";
	var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(token)));
	User? user = null;
	var conn = await ds.OpenConnectionAsync(ctx.RequestAborted);
	try {
		await using (var cmd = Command(conn, authSql, hash, Now))
		await using (var r = await Read(cmd, ctx.RequestAborted)) {
			if (await r.ReadAsync(ctx.RequestAborted)) user = new User(r.GetInt64(0), r.GetString(1));
		}
		if (!header.StartsWith("Bearer ", StringComparison.Ordinal) || user is null) {
			await Reply(unauthorized, 401).ExecuteAsync(ctx);
			return;
		}
		if (upstream != "") {
			await conn.DisposeAsync();
			var client = httpClients.CreateClient("upstream");
			using var resp = await client.GetAsync(upstream, ctx.RequestAborted);
			var body = await resp.Content.ReadAsStringAsync(ctx.RequestAborted);
			if (body != """{"ok":true}""") throw new InvalidOperationException("upstream: " + body);
			conn = await ds.OpenConnectionAsync(ctx.RequestAborted);
		}
		ctx.Items[typeof(User)] = user;
		ctx.Items[typeof(DbConnection)] = conn;
		await next(ctx);
	} finally {
		await conn.DisposeAsync();
	}
});
app.UseRouting();

app.MapGet("/posts", async (HttpContext ctx, string? page) => {
	var user = (User)ctx.Items[typeof(User)]!;
	var pageNo = 1;
	if (!string.IsNullOrEmpty(page) && !int.TryParse(page, out pageNo)) pageNo = 0;
	var ct = ctx.RequestAborted;
	var posts = new List<ListPost>(20);
	var index = new Dictionary<long, ListPost>(20);
	var conn = (DbConnection)ctx.Items[typeof(DbConnection)]!;
	await using (var cmd = Command(conn, listSql, (pageNo - 1) * 20))
	await using (var r = await Read(cmd, ct)) {
		while (await r.ReadAsync(ct)) {
			var p = new ListPost {
				Id = r.GetInt64(0), Title = r.GetString(1), Slug = r.GetString(2), Summary = r.GetString(3),
				PublishedAt = Atom(r.GetString(4)), Author = new Author(r.GetInt64(5), r.GetString(6)),
			};
			index[p.Id] = p;
			posts.Add(p);
		}
	}
	if (posts.Count > 0) {
		var ids = posts.Select(p => (object)p.Id).ToArray();
		var inList = Placeholders(ids.Length);
		await using (var cmd = Command(conn, Q($"SELECT pt.post_id, t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id WHERE pt.post_id IN ({inList}) ORDER BY pt.post_id, t.name"), ids))
		await using (var r = await Read(cmd, ct)) {
			while (await r.ReadAsync(ct)) index[r.GetInt64(0)].Tags.Add(r.GetString(1));
		}
		await using (var cmd = Command(conn, Q($"SELECT post_id, COUNT(*) FROM symfony_demo_comment WHERE post_id IN ({inList}) GROUP BY post_id"), ids))
		await using (var r = await Read(cmd, ct)) {
			while (await r.ReadAsync(ct)) index[r.GetInt64(0)].CommentCount = r.GetInt64(1);
		}
	}
	return Reply(new ListResponse(user, pageNo, posts), 200);
});

app.MapGet("/posts/{slug}", async (HttpContext ctx, string slug) => {
	var user = (User)ctx.Items[typeof(User)]!;
	var ct = ctx.RequestAborted;
	var conn = (DbConnection)ctx.Items[typeof(DbConnection)]!;
	Post? p = null;
	await using (var cmd = Command(conn, postSql, slug))
	await using (var r = await Read(cmd, ct)) {
		if (await r.ReadAsync(ct)) {
			p = new Post {
				Id = r.GetInt64(0), Title = r.GetString(1), Slug = r.GetString(2), Summary = r.GetString(3),
				Content = r.GetString(4), PublishedAt = Atom(r.GetString(5)), Author = new Author(r.GetInt64(6), r.GetString(7)),
			};
		}
	}
	if (p is null) return Reply(notFound, 404);
	await using (var cmd = Command(conn, postTagsSql, p.Id))
	await using (var r = await Read(cmd, ct)) {
		while (await r.ReadAsync(ct)) p.Tags.Add(r.GetString(0));
	}
	await using (var cmd = Command(conn, commentsSql, p.Id))
	await using (var r = await Read(cmd, ct)) {
		while (await r.ReadAsync(ct)) p.Comments.Add(new Comment(r.GetInt64(0), r.GetString(1), r.GetString(2), Atom(r.GetString(3))));
	}
	return Reply(new PostResponse(user, p), 200);
});

app.MapFallback("{**path}", () => Reply(notFound, 404));

Console.WriteLine("listening " + Environment.GetEnvironmentVariable("BLOG_ADDR"));
app.Run();

static string Atom(string s) => string.Concat(s.AsSpan(0, 10), "T", s.AsSpan(11), "+00:00");

record User(long Id, string Username);
record Author(long Id, string Name);
record Error(string error);

class ListPost {
	public long Id { get; set; }
	public string Title { get; set; } = "";
	public string Slug { get; set; } = "";
	public string Summary { get; set; } = "";
	public string PublishedAt { get; set; } = "";
	public Author Author { get; set; } = null!;
	public List<string> Tags { get; set; } = [];
	public long CommentCount { get; set; }
}

record ListResponse(User User, int Page, List<ListPost> Posts);

record Comment(long Id, string Author, string Content, string PublishedAt);

class Post {
	public long Id { get; set; }
	public string Title { get; set; } = "";
	public string Slug { get; set; } = "";
	public string Summary { get; set; } = "";
	public string Content { get; set; } = "";
	public string PublishedAt { get; set; } = "";
	public Author Author { get; set; } = null!;
	public List<string> Tags { get; set; } = [];
	public List<Comment> Comments { get; set; } = [];
}

record PostResponse(User User, Post Post);

