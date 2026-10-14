# Blog API, bare Ruby (Rack + Puma)

The task of `spec/spec.md` with no web framework and no ORM: a plain Rack app
(`blog.rb`, `config.ru`) served by Puma in clustered mode (`puma.rb`).

| piece | version | why |
|---|---|---|
| Ruby | 4.0.7 (2026-09-15), `+YJIT +PRISM` | current stable branch (4.1 is a preview) |
| Puma | 8.0.2 | clustered: `BLOG_WORKERS` = N processes, `BLOG_THREADS` threads each — in the harness ⌈24/N⌉ = 3, one per database connection of the worker (Puma's MRI default is 5; with a pool of 3 connections, two of five threads would wait for one), `preload_app!` |
| YJIT | off, as Ruby ships it | `BLOG_YJIT=1` enables it in `config.ru` after loading the app, the way Rails 7.2+ does (`config.yjit = true`) — a tuning step |
| pg | 1.7.0 (precompiled `x86_64-linux` gem, bundles libpq 18) | `exec_params` (the server binds the parameters; unnamed statement), `$n` placeholders |
| trilogy | 2.13.1 | MySQL client maintained by GitHub and shipped in Rails core since 7.1; no libmysqlclient needed. No server-side prepares: values are inlined and escaped by the connection, as Rails does on it |
| connection_pool | 3.0.2 | one pool per worker, `BLOG_POOL` connections (default = threads; the stack passes ⌈24/N⌉, as for Node, Python and Swoole), opened lazily after fork; one connection per request (`with`), returned while the upstream is awaited |
| json | 2.18.0, the version that ships with Ruby 4.0.7 | `JSON.generate` with its defaults |
| rack | 3.2.7 | |
| upstream | stdlib `Net::HTTP`, one persistent connection per thread | |
| allocator | glibc malloc, Ruby's default | jemalloc, as the Dockerfile that `rails new` generates preloads it, would be a tuning step |

## Build Ruby (once, into `~/.local/ruby-4.0.7`, the default `RUBY_HOME` of `harness/stack/up.sh`)

Needs build-essential, libssl-dev, zlib1g-dev, libreadline-dev, libgmp-dev, libffi-dev and a
Rust toolchain for YJIT. libyaml is compiled into psych from source, so neither libyaml-dev on
the host nor libyaml in `blog-runtime` is needed.

    mkdir -p ~/.local/src/ruby-dl && cd ~/.local/src/ruby-dl
    curl -LO https://cache.ruby-lang.org/pub/ruby/4.0/ruby-4.0.7.tar.xz
    echo '47ef59413f7a4587ba6a6b78b14036eb5e36eec2ec0b90964801e88d56a3d375  ruby-4.0.7.tar.xz' | sha256sum -c
    curl -LO https://github.com/yaml/libyaml/releases/download/0.2.5/yaml-0.2.5.tar.gz
    echo 'c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4  yaml-0.2.5.tar.gz' | sha256sum -c
    tar xf ruby-4.0.7.tar.xz && tar xf yaml-0.2.5.tar.gz && cd ruby-4.0.7
    RUSTC=~/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin/rustc ./configure \
        --prefix=$HOME/.local/ruby-4.0.7 --enable-yjit --disable-install-doc \
        --with-libyaml-source-dir=$HOME/.local/src/ruby-dl/yaml-0.2.5
    make -j16 && make install
    ~/.local/ruby-4.0.7/bin/ruby --yjit -v   # ruby 4.0.7 ... +YJIT +PRISM

The prefix is baked into the binary: mount it into the container at the same path.

## Bundle the gems (into `vendor/bundle`)

    cd implementations/ruby
    PATH=~/.local/ruby-4.0.7/bin:$PATH bundle config set --local path vendor/bundle
    PATH=~/.local/ruby-4.0.7/bin:$PATH bundle install

## Run

    BLOG_DRIVER=pg|mysql BLOG_DSN=postgres://postgres:bench@127.0.0.1:55440/bench \
    BLOG_WORKERS=N [BLOG_THREADS=5] [BLOG_POOL=threads] BLOG_ADDR=127.0.0.1:8098 [BLOG_UPSTREAM=url] \
        ~/.local/ruby-4.0.7/bin/bundle exec puma -C puma.rb

MySQL DSN: `mysql://root:bench@127.0.0.1:53340/bench`. In the stack: `harness/stack/up.sh ruby <db>`
(container `blog-ruby`, port 8098): N workers × ⌈24/N⌉ threads (as many as the worker's database connections), in the waiting series 2 × ⌈C/N⌉ threads (`RUBY_THREADS`).
