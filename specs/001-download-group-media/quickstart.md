# Quickstart: Download Group Media

A runnable validation path proving the feature end-to-end, following the three user
stories in order. See [contracts/toddy_api.md](./contracts/toddy_api.md) for full
function signatures and [data-model.md](./data-model.md) for the structs referenced
below.

## Prerequisites

- Elixir/OTP and Zig toolchains installed per `research.md` R1–R2 (exact versions
  pinned in `.tool-versions`/`mix.exs` once the project is scaffolded).
- A built `libtdjson` shared library on the library/runtime path (research.md R3).
- A Telegram application `api_id`/`api_hash` pair from https://my.telegram.org
  (research.md R10) — one-time setup, independent of any specific user account.
- A personal Telegram account that is already a member of the target group, with
  access to receive its login verification code (SMS or another logged-in device).

## 1. Authenticate (validates User Story 1)

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
# Toddy.Session.status(session) #=> :wait_password
# Toddy.Session.submit_password(session, "...")

Toddy.Session.status(session)
# => :ready
```

**Expected outcome**: `status/1` reaches `:ready`. Stop the process and start a new
`Toddy.Session` with the same `session_dir` — `status/1` should report `:ready`
immediately, with no `submit_code`/`submit_password` calls (SC-001, SC-002).

## 2. Find the group and list its media (validates User Story 2)

```elixir
{:ok, group} = Toddy.Group.find(session, "My Telegram Group")
{:ok, media_messages} = Toddy.Group.list_media(session, group)

length(media_messages)
# => however many of the group's existing messages carry a photo/video/document/audio attachment
```

**Expected outcome**: every returned message has a non-nil `media` field (FR-005).
Trying `Toddy.Group.find/2` with a bogus identifier returns
`{:error, :group_not_found}` rather than an empty group (FR-004).

## 3. Download the media (validates User Story 3)

```elixir
downloads = Toddy.Download.fetch_all(session, media_messages, "./tmp/downloads")

Enum.count(downloads, &(Toddy.Download.status(&1) == :completed))
Enum.count(downloads, &(Toddy.Download.status(&1) == :failed))
```

**Expected outcome**:
- Every `:completed` download's file exists at its `destination_path` with a size on
  disk matching the source `MediaItem.size` (FR-008, SC-004).
- Re-running `fetch_all/3` with the same messages and destination produces the same
  `:completed` results with zero new files written (FR-007, SC-006) — confirm via
  `File.stat!/1` mtimes being unchanged, or by checking the destination directory's
  file count before and after.
- Any `:failed` entries carry a distinguishable `error` reason (FR-010) rather than a
  generic failure.

## Notes

- This guide intentionally stops at the public API; it is not a substitute for the
  `:unit` and `:integration` ExUnit suites described in `plan.md`'s Project Structure.
- Flood-wait handling (FR-013) and transient-failure retries (FR-009) are internal to
  `fetch/3`/`fetch_all/3` — nothing to trigger manually here; they are covered by the
  `:integration` suite against a real `libtdjson` build.
