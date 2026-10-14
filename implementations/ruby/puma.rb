# Puma in clustered mode: BLOG_WORKERS processes (N, one per CPU of the stack, as Puma's
# deployment guide says) with BLOG_THREADS threads each (default 5, Puma's MRI default).
#   bundle exec puma -C puma.rb
environment "production"
workers Integer(ENV.fetch("BLOG_WORKERS", 1))
threads_count = Integer(ENV.fetch("BLOG_THREADS", 5))
threads threads_count, threads_count
bind "tcp://#{ENV.fetch("BLOG_ADDR", "127.0.0.1:8098")}"
rackup File.expand_path("config.ru", __dir__)
# Load the app once in the master and fork: workers share its pages copy-on-write. Database
# connections and the upstream client are created lazily, inside the workers.
preload_app!
tag "blog-ruby"
