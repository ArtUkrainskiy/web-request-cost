# Blog API, .NET "bare" variant

The task from `spec/spec.md` on ASP.NET Core 10 minimal APIs (Kestrel, `WebApplication.CreateBuilder`, as the `dotnet new web` template),
ADO.NET without an ORM: Npgsql 10.0.3 (`NpgsqlDataSource`) and MySqlConnector 2.6.2 (`MySqlDataSource`), each
with the driver's own pool (`Maximum Pool Size` = `BLOG_POOL`, 24; the drivers' default session reset when a connection goes back to the pool). One connection per request, opened in the authentication middleware and passed to the endpoint; closed while the upstream is awaited. Statements run as the drivers do by default (Npgsql: unnamed, MySqlConnector: text protocol). JSON through
System.Text.Json with the minimal-API defaults (`JsonSerializerDefaults.Web`) and snake_case names. Upstream call through
`IHttpClientFactory`. One process, like Go.

## Build

.NET SDK 10.0.402 (runtime 10.0.13, current LTS), installed without sudo:

    curl -sSL -o dotnet-install.sh https://dot.net/v1/dotnet-install.sh
    bash dotnet-install.sh --channel 10.0 --version 10.0.402 --install-dir ~/.dotnet
    DOTNET_CLI_TELEMETRY_OPTOUT=1 ~/.dotnet/dotnet publish -c Release -o out

`out/` is a framework-dependent Release publish (portable `linux-x64`, ~2.5 MB); the container mounts `~/.dotnet`
read-only as the shared runtime, the way Node is mounted from `~/.nvm` — the same layout as the official
`mcr.microsoft.com/dotnet/aspnet` image plus a framework-dependent app, the usual production container.

## Run

    BLOG_DRIVER=pgsql BLOG_DSN='Host=127.0.0.1;Port=55440;Database=bench;Username=postgres;Password=bench' \
    BLOG_POOL=24 BLOG_ADDR=127.0.0.1:8100 ~/.dotnet/dotnet out/Blog.dll

    BLOG_DRIVER=mysql BLOG_DSN='Server=127.0.0.1;Port=53340;Database=bench;User ID=root;Password=bench;SslMode=None' ...

`BLOG_DSN` is an ADO.NET connection string; `BLOG_UPSTREAM=<url>` makes every authenticated request call that URL
and require `{"ok":true}`.

## Settings that matter for memory

- GC: the Web SDK default, Server GC (concurrent) with DATAS (dynamic adaptation, on by default since .NET 9). No
  `GCHeapHardLimit`: Go runs without `GOMEMLIMIT`, and the runtime already caps the heap at 75% of a cgroup memory
  limit (40 GB in `up.sh`, so it never binds). `DOTNET_gcServer=0` gives Workstation GC,
  `DOTNET_GCDynamicAdaptationMode=0` gives the pre-.NET 9 Server GC (one heap per CPU, about 2× the RSS).
- `InvariantGlobalization=true`: `blog-runtime` has no libicu (as in the chiseled .NET images).
- Logging: the template defaults (`Microsoft.AspNetCore` at Warning) plus `System.Net.Http.HttpClient` at Warning,
  otherwise `IHttpClientFactory` logs four Information lines per upstream call.
- Slim builder, source-generated JSON, Npgsql automatic preparation and Native AOT are tuning steps, not used here.
