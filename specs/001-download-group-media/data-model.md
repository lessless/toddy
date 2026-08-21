# Phase 1 Data Model: Download Group Media

Entities below map directly to the spec's Key Entities section. All are plain Elixir
structs (Principle II — no raw TDLib JSON leaks past this layer); `Toddy.Session` is
additionally a GenServer that owns the mutable connection state.

## Toddy.Session (GenServer state — spec entity: "Telegram Account (Session)")

| Field | Type | Notes |
|---|---|---|
| `phone_number` | `String.t()` | Supplied at session start (FR-001). |
| `session_dir` | `String.t()` | TDLib database directory; created `0700` (FR-002, research.md R6). |
| `native` | reference (opaque) | Handle returned by `Toddy.Native.TdJson.create/0`. |
| `auth_state` | `:unauthenticated \| :wait_code \| :wait_password \| :ready \| :closed` | Mirrors TDLib's `authorizationState` updates. |
| `pending_requests` | `%{extra_id => GenServer.from()}` | Correlation map for in-flight requests (research.md R5). |
| `subscribers` | `[pid()]` | Processes registered to receive unsolicited update events (used internally by `Toddy.Group`/`Toddy.Download`, not part of the public contract). |

**Validation rules**:
- `auth_state` MUST only move forward through `:unauthenticated → :wait_code →
  [:wait_password] → :ready` (TDLib skips `:wait_password` when 2FA is disabled), or to
  `:closed` from any state (FR-001, US1 acceptance scenarios).
- A request MUST NOT be sent to TDLib while `auth_state` is not `:ready`, except the
  authentication requests themselves (`setAuthenticationPhoneNumber`, `checkCode`,
  `checkPassword`).

**Lifecycle**: created once per authenticated account; persists across process
restarts via `session_dir` (FR-002) — a new `Toddy.Session` pointed at the same
directory reconnects without re-authenticating (SC-002).

## Toddy.Group (spec entity: "Group")

| Field | Type | Notes |
|---|---|---|
| `id` | `integer()` | TDLib chat ID. |
| `title` | `String.t()` | Exact group title, as returned by TDLib. |

**Validation rules**: resolved only from a chat TDLib reports as a basic group or
supergroup the authenticated account is a member of (spec Assumptions); resolution
failure surfaces as `{:error, :group_not_found}` (FR-004), never an empty `Group`.

## Toddy.Message (spec entity: "Message")

| Field | Type | Notes |
|---|---|---|
| `id` | `integer()` | TDLib message ID. |
| `chat_id` | `integer()` | Owning `Toddy.Group.id`. |
| `date` | `DateTime.t()` | Message timestamp. |
| `sender` | `String.t() \| integer()` | Sender display name or ID, best-effort (not spec-critical). |
| `media` | `Toddy.MediaItem.t() \| nil` | `nil` for messages without an attachment; only messages with non-nil `media` are returned by media-discovery calls (FR-005). |

## Toddy.MediaItem (spec entity: "Media Item")

| Field | Type | Notes |
|---|---|---|
| `remote_file_id` | `String.t()` | TDLib's unique remote file identifier — the dedup key (FR-007). |
| `type` | `:photo \| :video \| :document \| :audio \| :voice_note` | Derived from the message's `content.@type` (research.md R7). |
| `size` | `non_neg_integer()` | Expected byte size, from TDLib's file metadata — the value FR-008 verifies against. |
| `file_name` | `String.t() \| nil` | Original filename when TDLib provides one (documents); `nil` for types without one (e.g. voice notes). |

**Validation rules**: `remote_file_id` is the sole identity used for deduplication —
two `MediaItem`s with the same `remote_file_id` are the same download target
regardless of `file_name` or which message referenced them (FR-007).

## Toddy.Download (spec entity: "Download")

| Field | Type | Notes |
|---|---|---|
| `remote_file_id` | `String.t()` | Foreign key to the `MediaItem` being downloaded; also the dedup/lookup key. |
| `destination_path` | `String.t()` | Caller-supplied local path (FR-006). |
| `status` | `:pending \| :in_progress \| :completed \| :failed` | Exposed to the caller for batch tracking (FR-011). |
| `error` | `atom() \| String.t() \| nil` | Present only when `status == :failed`; distinguishes cause (FR-010): `:media_unavailable`, `:insufficient_storage`, `:destination_not_writable`, `:retries_exhausted`, etc. |
| `bytes_downloaded` | `non_neg_integer()` | Progress indicator, sourced from TDLib's `updateFile` pushes (research.md R8); informational, not spec-required but a natural byproduct of FR-011. |

**State transitions**:

```
:pending → :in_progress → :completed
                        ↘ :failed
```

- `:pending → :in_progress`: download request issued to TDLib (`downloadFile` sent).
- `:in_progress → :completed`: `updateFile` reports completion AND the copied file's
  size on disk matches `MediaItem.size` (FR-008); a size mismatch instead produces
  `:failed` with `error: :size_mismatch`.
- `:in_progress → :failed`: media no longer available, destination not writable,
  insufficient local storage, or the bounded transient-failure retry budget (FR-009)
  is exhausted. A flood-wait response (FR-013) does NOT transition the state — it
  pauses and retries transparently while `status` remains `:in_progress`.
- A `Download` already `:completed` for a given `remote_file_id` + `destination_path`
  is never re-created; a repeat request short-circuits to the existing record
  (FR-007, SC-006).

## Relationships

```
Toddy.Session (1) ──authenticates──> (1) Telegram account
Toddy.Session (1) ──queries──> (1) Toddy.Group per operation (spec: single group per operation)
Toddy.Group (1) ──has many──> Toddy.Message
Toddy.Message (0..1) ──carries──> Toddy.MediaItem
Toddy.MediaItem (1) ──produces──> (0..1) Toddy.Download (one per distinct destination_path)
```
