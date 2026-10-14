# rackup file for Puma (see puma.rb). YJIT stays off, as Ruby ships it; BLOG_YJIT=1 enables it after
# the app is loaded, the way Rails >= 7.2 does (config.yjit = true).
require_relative "blog"

threads = Integer(ENV.fetch("BLOG_THREADS", 5))
run Blog::App.new(
  driver: ENV.fetch("BLOG_DRIVER", "pg"),
  dsn: ENV.fetch("BLOG_DSN"),
  pool: Integer(ENV.fetch("BLOG_POOL", threads)),
  upstream: ENV["BLOG_UPSTREAM"],
)

RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && ENV["BLOG_YJIT"] == "1"
