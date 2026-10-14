# Blog API from spec/spec.md as a plain Rack app: no framework, no ORM.
# PostgreSQL through the pg gem (exec_params: parameters bound by the server), MySQL through
# trilogy (text protocol, values escaped by the driver). One connection_pool per Puma worker, sized to the
# thread count; connections are opened lazily, so they never cross a fork.
#
#   BLOG_DRIVER=pg|mysql BLOG_DSN=postgres://... | mysql://user:pass@host:port/db
#   BLOG_POOL (default: threads per worker) BLOG_UPSTREAM (optional URL answering {"ok":true})
require "digest"
require "json"
require "uri"
require "net/http"
require "connection_pool"
require "rack/utils"

module Blog
  NOW = "2026-10-13 00:00:00"
  JSON_TYPE = { "content-type" => "application/json" }.freeze
  UNAUTHORIZED = JSON.generate({ "error" => "unauthorized" }).freeze
  NOT_FOUND = JSON.generate({ "error" => "not found" }).freeze

  # PostgreSQL: exec_params, the pg gem's call for a statement with parameters (? placeholders become $1, $2, …).
  class Pg
    def initialize(dsn)
      require "pg"
      @conn = PG.connect(dsn)
      @sql = {}
    end

    def at(col) = "to_char(#{col}, 'YYYY-MM-DD HH24:MI:SS')"

    def query(sql, params)
      text = @sql[sql] ||= begin
        n = 0
        sql.gsub("?") { "$#{n += 1}" }
      end
      @conn.exec_params(text, params).values
    end
  end

  # MySQL: trilogy has no server-side prepared statements (neither does Rails on it); values
  # are inlined, strings escaped by the connection. Integers come back cast.
  class My
    def initialize(dsn)
      require "trilogy"
      u = URI(dsn)
      @conn = Trilogy.new(host: u.host, port: u.port || 3306, username: URI.decode_www_form_component(u.user),
                          password: URI.decode_www_form_component(u.password || ""), database: u.path.delete_prefix("/"),
                          encoding: "utf8mb4")
    end

    def at(col) = "DATE_FORMAT(#{col}, '%Y-%m-%d %H:%i:%s')"

    def query(sql, params)
      i = -1
      text = sql.gsub("?") do
        v = params[i += 1]
        v.is_a?(Integer) ? v.to_s : "'#{@conn.escape(v)}'"
      end
      @conn.query(text).rows
    end
  end

  def self.atom(s) = "#{s[0, 10]}T#{s[11..]}+00:00"
  def self.placeholders(n) = Array.new(n, "?").join(", ")

  class App
    def initialize(driver:, dsn:, pool:, upstream: nil)
      klass = driver == "pg" ? Pg : My
      @pool = ConnectionPool.new(size: pool, timeout: 30) { klass.new(dsn) }
      @upstream = upstream && !upstream.empty? ? URI(upstream) : nil
    end

    # Each Puma thread keeps one persistent connection to the upstream.
    def upstream_ok?
      http = Thread.current[:blog_upstream] ||= Net::HTTP.new(@upstream.host, @upstream.port).tap do |h|
        h.read_timeout = 30
        h.start
      end
      http.request(Net::HTTP::Get.new(@upstream.request_uri)).body == '{"ok":true}'
    end

    def reply(status, body) = [status, JSON_TYPE.dup, [body]]

    # Authentication runs for every request, before routing, as in the spec. The statements of a
    # request share one connection, returned to the pool while the upstream is awaited.
    def call(env)
      auth = env["HTTP_AUTHORIZATION"] || ""
      hash = Digest::SHA256.hexdigest(auth[7..] || "")
      return @pool.with { |db| authenticate(db, auth, hash) { |user| respond(db, env, user) } } unless @upstream

      user = @pool.with { |db| authenticate(db, auth, hash) { |u| u } }
      return user if user.is_a?(Array)
      raise "upstream: unexpected reply" unless upstream_ok?

      @pool.with { |db| respond(db, env, user) }
    end

    # Yields the user of a valid "Bearer <token>"; the 401 reply otherwise.
    def authenticate(db, auth, hash)
      row = db.query("SELECT u.id, u.username FROM blog_session s JOIN symfony_demo_user u ON u.id = s.user_id WHERE s.token_hash = ? AND s.expires_at > ?", [hash, NOW]).first
      return reply(401, UNAUTHORIZED) if !auth.start_with?("Bearer ") || row.nil?

      yield({ "id" => row[0].to_i, "username" => row[1] })
    end

    def respond(db, env, user)
      path = env["PATH_INFO"]
      if path == "/posts"
        query = Rack::Utils.parse_query(env["QUERY_STRING"])
        page = query.key?("page") ? query["page"].to_s.to_i : 1
        reply(200, JSON.generate(list_posts(db, user, page)))
      elsif path.start_with?("/posts/")
        slug = Rack::Utils.unescape_path(path[7..]).force_encoding(Encoding::UTF_8)
        post = show_post(db, slug)
        post ? reply(200, JSON.generate({ "user" => user, "post" => post })) : reply(404, NOT_FOUND)
      else
        reply(404, NOT_FOUND)
      end
    end

    def list_posts(db, user, page)
      posts = []
      index = {}
      db.query("SELECT p.id, p.title, p.slug, p.summary, #{db.at("p.published_at")}, u.id, u.full_name FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id ORDER BY p.published_at DESC LIMIT 20 OFFSET ?", [(page - 1) * 20]).each do |r|
        id = r[0].to_i
        post = { "id" => id, "title" => r[1], "slug" => r[2], "summary" => r[3], "published_at" => Blog.atom(r[4]),
                 "author" => { "id" => r[5].to_i, "name" => r[6] }, "tags" => [], "comment_count" => 0 }
        index[id] = post
        posts << post
      end
      unless posts.empty?
        ids = index.keys
        db.query("SELECT pt.post_id, t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id WHERE pt.post_id IN (#{Blog.placeholders(ids.size)}) ORDER BY pt.post_id, t.name", ids).each do |id, name|
          index[id.to_i]["tags"] << name
        end
        db.query("SELECT post_id, COUNT(*) FROM symfony_demo_comment WHERE post_id IN (#{Blog.placeholders(ids.size)}) GROUP BY post_id", ids).each do |id, n|
          index[id.to_i]["comment_count"] = n.to_i
        end
      end
      { "user" => user, "page" => page, "posts" => posts }
    end

    def show_post(db, slug)
      r = db.query("SELECT p.id, p.title, p.slug, p.summary, p.content, #{db.at("p.published_at")}, u.id, u.full_name FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id WHERE p.slug = ?", [slug]).first
      return nil unless r
      id = r[0].to_i
      tags = db.query("SELECT t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id WHERE pt.post_id = ? ORDER BY t.name", [id]).map(&:first)
      comments = db.query("SELECT c.id, u.full_name, c.content, #{db.at("c.published_at")} FROM symfony_demo_comment c JOIN symfony_demo_user u ON u.id = c.author_id WHERE c.post_id = ? ORDER BY c.published_at, c.id", [id]).map do |c|
        { "id" => c[0].to_i, "author" => c[1], "content" => c[2], "published_at" => Blog.atom(c[3]) }
      end
      { "id" => id, "title" => r[1], "slug" => r[2], "summary" => r[3], "content" => r[4], "published_at" => Blog.atom(r[5]),
        "author" => { "id" => r[6].to_i, "name" => r[7] }, "tags" => tags, "comments" => comments }
    end
  end
end
