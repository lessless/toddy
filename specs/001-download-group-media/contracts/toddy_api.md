# Public API Contract: Toddy

This is a library, not a network service — its "contract" is the public Elixir module
surface every downstream caller programs against. Every function returns idiomatic
Elixir terms (Constitution Principle II): tagged tuples, structs, or plain values —
never raw TDLib JSON.

## `Toddy.Session`

Owns one authenticated TDLib connection (data-model.md `Toddy.Session`). One process
per authenticated account (spec Assumptions: single account per operation).

```elixir
@spec start_link(
        phone_number: String.t(),
        session_dir: String.t(),
        api_id: pos_integer(),
        api_hash: String.t()
      ) :: GenServer.on_start()
def start_link(opts)

@spec status(session :: GenServer.server()) ::
        :unauthenticated | :wait_code | :wait_password | :ready | :closed
def status(session)

@spec submit_code(session :: GenServer.server(), code :: String.t()) ::
        :ok | {:error, :invalid_code}
def submit_code(session, code)

@spec submit_password(session :: GenServer.server(), password :: String.t()) ::
        :ok | {:error, :invalid_password}
def submit_password(session, password)
```

- `api_id`/`api_hash` are the TDLib application credentials (research.md R10) — required
  config, not part of the per-login flow.
- `start_link/1` against a `session_dir` that already holds a valid TDLib session
  reconnects directly to `status: :ready`, with no `submit_code`/`submit_password`
  calls needed (FR-002, SC-002, US1 acceptance scenario 3).
- `submit_password/2` is only meaningful when `status/1` reports `:wait_password`;
  calling it otherwise is a caller error (`{:error, :invalid_password}` is reserved
  for TDLib rejecting the password itself, not for a state error).

## `Toddy.Group`

```elixir
@spec find(session :: GenServer.server(), identifier :: integer() | String.t()) ::
        {:ok, Toddy.Group.t()} | {:error, :group_not_found}
def find(session, identifier)

@spec list_media(session :: GenServer.server(), group :: Toddy.Group.t()) ::
        {:ok, [Toddy.Message.t()]} | {:error, term()}
def list_media(session, group)
```

- `find/2` accepts either the group's TDLib ID or its exact title (FR-003); a group
  the account is not a member of returns `{:error, :group_not_found}` (FR-004), never
  an ambiguous empty result.
- `list_media/2` returns only messages with a non-nil `media` field (FR-005), scanning
  the group's full existing history at call time (FR-012 — historical scan only).

## `Toddy.Download`

```elixir
@spec fetch(
        session :: GenServer.server(),
        message :: Toddy.Message.t(),
        destination_path :: String.t()
      ) :: {:ok, Toddy.Download.t()} | {:error, term()}
def fetch(session, message, destination_path)

@spec fetch_all(
        session :: GenServer.server(),
        messages :: [Toddy.Message.t()],
        destination_dir :: String.t()
      ) :: [Toddy.Download.t()]
def fetch_all(session, messages, destination_dir)

@spec status(download :: Toddy.Download.t()) ::
        :pending | :in_progress | :completed | :failed
def status(download)
```

- `fetch/3` is synchronous from the caller's point of view: it returns once the
  download reaches `:completed` or `:failed` (retries, including flood-wait handling,
  happen internally per FR-009/FR-013 and are not exposed as separate calls).
- `fetch/3` called again for a `message` whose media was already fully downloaded to
  the same `destination_path` returns the existing `:completed` `Toddy.Download`
  immediately, without re-downloading (FR-007, SC-006).
- `fetch_all/3` is the batch entry point for US3: it drives `fetch/3` for each message
  and returns every resulting `Toddy.Download`, mixing `:completed` and `:failed`
  entries rather than aborting the batch on the first failure (US3 acceptance scenario
  4, FR-010, FR-011).

## `Toddy.Probes` (Constitution Principle VII)

Not called directly by library consumers — listed here because it is the sole
observability surface `Toddy.Session`/`Toddy.Group`/`Toddy.Download` are allowed to
call into (no direct `Logger`/telemetry calls from domain code).

```elixir
def session_authenticated(session_dir)
def group_not_found(identifier)
def download_started(remote_file_id, destination_path)
def download_completed(remote_file_id, bytes)
def download_failed(remote_file_id, reason)
def rate_limited(retry_after_seconds)
```

Each probe function's implementation (what it actually logs/emits) is an
implementation detail; the contract other domain modules rely on is the function
names and arguments above.
