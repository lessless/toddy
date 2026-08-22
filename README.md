# Toddy

A minimal Elixir wrapper over [TDLib](https://github.com/tdlib/td) (via a thin
[Zigler](https://github.com/E-xyza/zigler) NIF) that authenticates a personal
Telegram account, locates a group you belong to, and downloads the media in that
group's message history to local storage. See
[`specs/001-download-group-media/`](specs/001-download-group-media/) for the full
spec, plan, and task breakdown, and [`.specify/memory/constitution.md`](.specify/memory/constitution.md)
for the project's governing principles.

## Prerequisites

### 1. `libtdjson`

Toddy links against TDLib's JSON-interface shared library at compile time via
`pkg-config`. Install it before running `mix compile`:

```sh
# macOS — use --HEAD, not the stable formula (see warning below)
brew install tdlib --HEAD

# Debian/Ubuntu — no official package; build from source and ensure the
# resulting libtdjson.pc is on PKG_CONFIG_PATH. See https://github.com/tdlib/td#building

# FreeBSD — also no package; build from source (see the FreeBSD section below)
```

> [!WARNING]
> Don't use a distro/package-manager "stable" TDLib build here. Homebrew's
> stable formula (1.8.0) both gets rejected by Telegram's live servers
> (`UPDATE_APP_TO_LOGIN` — its protocol layer is too old) *and*, on some
> versions, uses a different wire format for `setTdlibParameters` than
> current TDLib does (see research.md R3's addenda for the full story — this
> cost real debugging time). CI and this project's own testing are verified
> against `tdlib/td` commit `022d60202e446ad1287b9fb68e687c8a0760788b`
> specifically; building from a different recent commit is likely fine, but
> if login gets stuck at `:unauthenticated` or fails with a confusing
> `"Valid api_id must be provided"` error even with a known-good `api_id`,
> that commit is a known-working fallback to pin to.

Verify it's discoverable:

```sh
pkg-config --modversion tdjson
```

<details>
<summary><strong>Building on FreeBSD</strong> (untested by this project — macOS above is the
platform actually verified this session; adapt as needed)</summary>

```sh
# Build deps. openssl/zlib ship in the base system; these are the rest.
pkg install cmake gperf pkgconf git

git clone https://github.com/tdlib/td.git /tmp/td
git -C /tmp/td checkout 022d60202e446ad1287b9fb68e687c8a0760788b  # see warning above
cmake -S /tmp/td -B /tmp/td/build -DCMAKE_BUILD_TYPE=Release -DTD_ENABLE_LTO=OFF
cmake --build /tmp/td/build --target tdjson -- -j$(sysctl -n hw.ncpu)
cmake --install /tmp/td/build   # defaults to /usr/local, already on pkg-config's search path

# If pkg-config still can't find it, the linker's shared-library cache may
# need refreshing (a fresh install to /usr/local/lib is often not picked up
# until this runs):
ldconfig -m /usr/local/lib
```

Zigler's own README lists FreeBSD as a supported target ("tested, but not
subjected to CI"), and Zig ships official FreeBSD (x86_64/aarch64) binaries at
<https://ziglang.org/download/>, so `mix zig.get` (see below) should work
unmodified. Elixir/Erlang: `pkg install elixir` pulls in `erlang` as a
dependency, though the packaged versions can lag — if you need to match this
project's pinned `.tool-versions` (Elixir 1.20.2 / OTP 29) exactly, building
`lang/erlang` and `lang/elixir` from ports gets you a specific version. `mise`
(used elsewhere in this README for fnox) doesn't have a confirmed official
FreeBSD binary as of this writing — `pkg install rust && cargo install mise`
would likely work but is unverified; native `pkg`/ports is the safer bet here.

</details>

### 2. Zig toolchain

Handled automatically — run `mix zig.get` after `mix deps.get` to fetch the Zig
version Zigler expects into its own cache directory (no system Zig install
required, though one on `PATH` is also fine).

### 3. Telegram application credentials

TDLib requires an `api_id`/`api_hash` pair identifying your application,
independent of any specific user account. Obtain one (free, one-time) at
<https://my.telegram.org> and keep it out of source control (e.g. via
environment variables, as in the example below).

## Installation

```elixir
def deps do
  [
    {:toddy, "~> 0.1.0"}
  ]
end
```

## Quickstart

A runnable walkthrough of all three capabilities, in order. See
[`specs/001-download-group-media/contracts/toddy_api.md`](specs/001-download-group-media/contracts/toddy_api.md)
for full function signatures.

### 1. Authenticate

```elixir
{:ok, session} =
  Toddy.Session.start_link(
    phone_number: "+15551234567",
    session_dir: "./tmp/session",
    api_id: System.fetch_env!("TG_API_ID") |> String.to_integer(),
    api_hash: System.fetch_env!("TG_API_HASH")
  )

Toddy.Session.status(session)
# => :wait_code

Toddy.Session.submit_code(session, "12345")
# If the account has 2FA enabled:
# Toddy.Session.submit_password(session, "...")

Toddy.Session.status(session)
# => :ready
```

Starting a new `Toddy.Session` against the same `session_dir` later reconnects
straight to `:ready`, with no re-authentication needed — the session directory
is created `0700` and TDLib's session files are kept `0600`.

### 2. Find a group and list its media

```elixir
{:ok, group} = Toddy.Group.find(session, "My Telegram Group")
{:ok, media_messages} = Toddy.Group.list_media(session, group)
```

### 3. Download the media

```elixir
downloads = Toddy.Download.fetch_all(session, media_messages, "./tmp/downloads")

# Or, organized into dd-mm-yyyy folders by the date each message was posted:
downloads = Toddy.Download.fetch_all(session, media_messages, "./tmp/downloads", group_by: :date)
# => ./tmp/downloads/21-08-2026/photo.jpg
```

Downloads are deduplicated by TDLib's remote file ID, verified by size on
completion, automatically retried on transient failures, and automatically wait
out Telegram's flood-wait rate limiting rather than failing.

## Observability

Every operation (authenticate, find a group, list its media, download one file,
download a batch) emits exactly one consolidated
["wide event"](https://jeremymorrell.dev/blog/a-practitioners-guide-to-wide-events/)
— rather than several scattered log lines — as an OpenTelemetry span, via the
lightweight `opentelemetry_api` package. Every field collected during the
operation (identifiers, outcome, counts, failure reasons, etc.) is set as a
span attribute, and a failure-ish outcome (`:failed`, `:not_found`,
`:partial_failure`) sets an error span status. Span names: `session_authenticate`,
`group_find`, `group_list_media`, `download`, `download_batch`, `rate_limited`.

OpenTelemetry spans are the *sole* emission mechanism — Toddy does not use
`Logger` for this. To see them, your application needs the full `opentelemetry`
SDK and an exporter configured (Toddy only depends on the API package, so this
is your choice, same as any other OTel-instrumented dependency):

```elixir
# in your application's deps
{:opentelemetry, "~> 1.5"}

# in your application's config — otel_exporter_stdout ships with :opentelemetry
# itself and is enough to see spans locally; swap in {:opentelemetry_exporter, ...}
# and the OTLP exporter for a real backend.
config :opentelemetry,
  traces_exporter: {:otel_exporter_stdout, []}
```

## Development

- `mix test` — unit tests (mocked TDLib responses, no native dependency needed).
- `mix test --include integration` — adds the integration suite, which needs a
  real `libtdjson` build (see Prerequisites) but not live credentials for most
  cases — see below for the tests that do.
- `mix format` / `zig fmt src/*.zig` — formatting (also covered by `mix format`
  via the Zigler formatter plugin).

### Live end-to-end credentials (optional)

Most of the integration suite runs against a real `libtdjson` without needing
real Telegram credentials. A few tests go further — reaching `:wait_code`, and
a full login + reconnect-without-reauth check (SC-001, SC-002) — and only run
when these environment variables are present (they're skipped otherwise):

| Variable | What it is |
|---|---|
| `TG_API_ID`, `TG_API_HASH` | Your own app credentials from <https://my.telegram.org> — the widely-shared demo id/hash used elsewhere in this repo's manual checks gets rejected by Telegram with `UPDATE_APP_TO_LOGIN`, so this must be a real registration. |
| `TG_TEST_PHONE` | A real phone number you can receive a login code on. |
| `TG_TEST_CODE` | The login code for that number, for the specific run — inherently short-lived, so it's supplied per-run rather than stored. |

This repo manages the first three via [fnox](https://github.com/jdx/fnox)
(age-encrypted secrets; the encrypted `fnox.toml` is kept local/gitignored
here rather than committed, though fnox's usual pitch is that you safely
*can* commit it). One-time setup:

```sh
# fnox itself, and age for keypair generation
mise use -g fnox
brew install age   # or your platform's equivalent

# generate your own age keypair — private key stays at ~/.config/fnox/age.txt,
# outside the repo, never committed; fnox.toml's [providers.age].key_file
# already points there
age-keygen -o ~/.config/fnox/age.txt

# put the printed public key into fnox.toml's [providers.age].recipients,
# then store your real credentials (never paste real secrets in chat/PRs):
fnox set TG_API_ID <your-api-id>
fnox set TG_API_HASH <your-api-hash>
fnox set TG_TEST_PHONE <your-test-phone-number>
```

Then run the suite with secrets injected:

```sh
fnox exec -- mix test --include integration
```

For the full login+reconnect test, pass `TG_TEST_CODE` for that single run
only (it expires in minutes, so it isn't stored in fnox):

```sh
TG_TEST_CODE=12345 fnox exec -- mix test --include integration
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/toddy>.
