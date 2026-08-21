# Phase 0 Research: Download Group Media

Each item below resolves one unknown from Technical Context or one architecturally
significant decision needed before Phase 1 design.

## R1. Elixir/OTP version to target

**Decision**: Target Elixir `~> 1.20` on OTP 27+ (validated against OTP 29). Pin the
exact patch version in `.tool-versions` at project setup time.

**Rationale**: 1.20.3 is the current stable Elixir release as of this research
(2026-08-21), built against OTP 29, and Elixir 1.20 supports OTP 27–29 — giving
headroom on the host's Erlang version without pinning to a single OTP release.

**Alternatives considered**: Pinning to an older Elixir/OTP pair for broader
compatibility — rejected; nothing in this feature needs legacy support, and the
constitution favors reproducible, current, explicitly pinned versions over broad
compatibility.

## R2. Zig/Zigler version to target

**Decision**: Target Zigler `~> 0.16` (latest published Hex release), which pairs
with Zig `0.16.x`. Pin the exact versions in `mix.exs` and let Zigler manage the Zig
toolchain download (`mix zig.get`) per its own documented workflow.

**Rationale**: Zig 0.16.0 is the current stable Zig release; Zigler's own versioning
tracks the Zig version it targets, so using matching `0.16` releases of both avoids
compatibility drift.

**Alternatives considered**: Vendoring a separately-managed Zig toolchain outside of
Zigler's own fetch mechanism — rejected as unnecessary complexity; Zigler's built-in
toolchain management already satisfies Constitution Principle IV (pinned, documented,
reproducible from a clean checkout).

## R3. Acquiring `libtdjson`

**Decision**: Require a pre-built `libtdjson` shared library to be present on the
build/runtime host (installed via system package manager where available, or built
from a pinned `tdlib/td` commit SHA using a documented, out-of-band build script kept
outside the Elixir/Zig build). The Zig NIF links against this library; it does not
compile TDLib's C++ sources itself.

**Rationale**: TDLib's C++ codebase requires CMake, a C++17 toolchain, OpenSSL, zlib,
and gperf, and takes significant time to build. Triggering that build from `mix
compile` (transitively, from Zig's build) would make every clean build slow and
platform-fragile, and would work against Constitution Principle VI's "minimal native
surface" — the point is a thin Zig layer, not an embedded C++ build system. TDLib does
not publish frequent tagged GitHub releases; the standard practice for consumers is to
pin an exact commit SHA, which the project documents (Constitution Principle IV) and
verifies at runtime via `getOption("version")` in the integration suite.

**Alternatives considered**: (a) Vendor TDLib source and drive its CMake build from
`build.zig` — rejected: slow, platform-fragile, contradicts the minimal-surface goal.
(b) Fetch prebuilt static binaries from a project-hosted artifact store at build time —
rejected for this minimal wrapper: it adds artifact-hosting and a cross-platform binary
matrix the spec does not call for; revisit only if manual `libtdjson` setup proves to
be a real adoption blocker.

**Addendum (discovered during implementation)**: Homebrew's `tdlib` stable formula
(1.8.0) compiled and linked correctly, but Telegram's live servers rejected the login
handshake with `UPDATE_APP_TO_LOGIN` (error 406) — the build's protocol layer was old
enough that Telegram refuses new logins with it entirely, independent of account
credentials. A `brew install tdlib --HEAD` (built from a current `tdlib/td` commit)
was required to get a login-capable build. This sharpens the "pin an exact commit SHA"
guidance above: the pin needs periodic refreshing to stay ahead of Telegram's
protocol-layer cutoff, not just picked once and left alone — a distro/package-manager
"stable" release is not a safe default assumption for this specific dependency. CI
(`.github/workflows/ci.yml`) builds from source accordingly rather than an apt/brew
package.

**Second addendum — pin to a verified commit (this is the resolution, not a new
problem)**: unpinned `--HEAD` immediately bit us — the very next commit past 1.8.0
(`022d602`, "Update version to 1.8.66") had *removed the `tdlibParameters` composite
type from `td_api.tl` entirely*, flattening `setTdlibParameters`'s fields directly
onto the request. Our code (correctly, for 1.8.0) nested those fields under a
`"parameters"` key; against `022d602` that nested object is simply an unrecognized
field, so every real field — including `api_id` — silently defaults to its zero value,
surfacing as TDLib's generic `"Valid api_id must be provided"` (a message that reads
like a credential problem but was actually a wire-format mismatch). Confirmed via the
build's own `td_api.tl` schema (`tdlibParameters` has zero occurrences in `022d602`,
vs. the nested type present in 1.8.0) and reproduced with a well-known non-secret
`api_id` (94575) to rule out anything credential-specific. Fixed by sending the fields
flat (`lib/toddy/session.ex`), matching `022d602`'s actual schema.

This is exactly the scenario R3's "pin an exact commit SHA" guidance exists for — the
wire format for this one request has now been observed to differ across three
adjacent points in TDLib's history (bare fields → wrapped in `parameters` → bare
fields again), so an unpinned build is not just a login-layer risk but a silent
protocol-shape risk. **Pinned commit: `022d602` (tdlib/td), verified working through
`authorizationStateWaitCode` against live Telegram infrastructure.** `.github/workflows/ci.yml`
still clones the default branch rather than this SHA — updating that to pin explicitly
is recommended follow-up, now that a concretely-verified commit exists to pin to.

## R4. TDLib interface: JSON client vs. raw C++ `Client`

**Decision**: Use TDLib's JSON interface (`td_json_client_create`, `_send`,
`_receive`, `_execute`, `_destroy`) rather than wrapping the raw C++ `Client` API.

**Rationale**: The JSON interface's entire surface is five C functions that pass
plain strings (UTF-8 JSON) across the FFI boundary — there is no TDLib C++ object
model to mirror in Zig. This lets the Zig layer stay pure marshaling (Principle VI)
while all TDLib API knowledge (request/response shapes, the `td_api.tl` schema) lives
in Elixir as plain maps/structs decoded with `Jason`.

**Alternatives considered**: Wrapping the raw C++ `Client` class — rejected: it would
require a C++ shim and push substantial TDLib-object-model logic into native code,
directly conflicting with Principles I and VI.

**Note**: `td_json_client.h` documents this interface as legacy — "will be removed in
TDLib 2.0.0" — in favor of a newer `td_create_client_id`/`td_send`/`td_receive`/
`td_execute` interface (integer client ids, process-wide receive/execute rather than
per-client). Still fully present and functional in the TDLib versions this project
targets; noted here so a future migration isn't a surprise, not acted on now since it
would invalidate no small amount of already-implemented, working code for no current
benefit.

## R5. Request/response correlation

**Decision**: Every outgoing JSON request gets a unique `@extra` string (generated in
Elixir, e.g. via `:erlang.unique_integer/1`). `Toddy.Session`'s receive loop reads
whatever `td_json_client_receive` returns next, and dispatches by `@extra`: a match
resolves the corresponding waiting caller; no match (an `@extra`-less payload) is an
unsolicited TDLib update and is routed to `Toddy.Probes`/subscribers instead.

**Rationale**: `td_json_client_send` is fire-and-forget and `_receive` returns
whatever is next in TDLib's internal queue — responses, unsolicited updates, and
authorization-state changes are all interleaved on the same channel. `@extra` is
TDLib's documented mechanism for correlating a specific response to its request.

**Alternatives considered**: Relying on response ordering — rejected: TDLib does not
guarantee responses arrive in request order, especially once updates are interleaved.

## R6. Session directory & file permissions (FR-002)

**Decision**: `Toddy.Session` creates the TDLib database directory with mode `0700`
*before* calling `setTdlibParameters`, and re-asserts `0600` on every regular file
directly under that directory immediately after each operation that could have caused
TDLib to create a new file (session start, and after authentication completes).

**Rationale**: TDLib creates its own session/database files once initialized; the
wrapper cannot control the mode TDLib uses internally, so it enforces the required
permissions from the Elixir side both before (directory) and after (files) TDLib
writes to it — satisfying FR-002 without depending on TDLib's own file-creation
behavior.

**Alternatives considered**: Relying solely on a restrictive process `umask` — rejected
as insufficient on its own: it depends on the deploying process's environment rather
than being an explicit, testable guarantee the library itself makes.

## R7. Discovering a group's media messages (FR-005)

**Decision**: Resolve the target group via `searchPublicChat`/the account's own chat
list (matching by ID or exact title per FR-003), then page backward through its
history with repeated `getChatHistory` calls (TDLib's standard 100-message page,
walking `from_message_id` backward), filtering each page in Elixir for messages whose
`content.@type` is one of `messagePhoto`, `messageVideo`, `messageDocument`, or
`messageVoiceNote`/`messageAudio`.

**Rationale**: TDLib has no single "list this chat's media" call; `getChatHistory`
plus content-type filtering is the standard approach, and doing the filtering and
pagination loop in Elixir (rather than any native code) keeps the Zig layer untouched
by this logic, per Principle VI.

**Alternatives considered**: TDLib's `searchChatMessages` with a `filter` (e.g.
`searchMessagesFilterPhotoAndVideo`) — narrower than the full media-type set the spec
requires (documents and voice notes need separate filter values / additional calls),
so plain history pagination with local filtering is simpler for a minimal wrapper and
avoids multiple filter-specific request types.

## R8. Downloading media to a caller-specified destination (FR-006, FR-008)

**Decision (revised during implementation)**: For each selected media item, call
`downloadFile` with `"synchronous": true` — the request itself blocks until the
download completes and returns the finished `file` object directly (`local.path`,
`local.is_downloading_completed`) as the correlated response — then copy that file
from TDLib's own storage path to the caller-supplied destination, then compare the
copied file's size on disk against the media item's reported `size` (FR-008) before
marking the `Download` as `:completed`.

**Rationale**: TDLib downloads into files it manages by internal file ID, not an
arbitrary caller path; a copy step is required regardless of interface choice.
`synchronous: true` reuses the request/response correlation engine (R5) directly —
no separate `updateFile` subscription/dispatch bookkeeping needed, which is simpler
for the same guarantee. (`Toddy.Session.subscribe/1` from R5 is kept as generic
foundational infrastructure — e.g. for a future feature — but no current user story
needs it.)

**Alternatives considered**: (a) Non-blocking `downloadFile` + waiting for `updateFile`
push(es) — the original plan; rejected on implementation because synchronous mode
achieves the identical outcome with substantially less state to manage. (b) Polling
`getFile` in a loop — rejected: redundant with either of the above.

## R9. Detecting and honoring flood-wait (FR-013)

**Decision**: Treat a TDLib JSON `error` response with `code: 429` as a flood-wait,
parse the retry-after duration from its `message` field (TDLib's documented
`"Too Many Requests: retry after N"` format), sleep for that duration, then
transparently re-issue the original request with a new `@extra`.

**Rationale**: TDLib surfaces flood-wait as a normal correlated error response (via
R5's `@extra` mechanism), not a special channel, so handling it is a matter of
inspecting the error code on the response path already built for every request.

**Alternatives considered**: Treating all errors uniformly under the FR-009 bounded
retry — rejected per the spec's Q3 clarification: flood-wait must be waited out
specifically (unbounded on attempt count, bounded by the server's own stated delay),
not folded into the generic transient-failure retry budget.

## R10. Application credentials (`api_id` / `api_hash`)

**Decision**: TDLib requires a Telegram application `api_id`/`api_hash` pair (obtained
once, out-of-band, from https://my.telegram.org) to initialize any client, independent
of which account subsequently logs in. The wrapper accepts these as required
configuration when starting a `Toddy.Session` (e.g. via `start_link` options or
application config) rather than treating them as a per-request input.

**Rationale**: This is a standard TDLib prerequisite (an application identity, not a
user credential) and is orthogonal to the phone/code/password flow FR-001 already
specifies; documenting it as setup configuration (see quickstart.md) is the reasonable
default rather than a scope change to the spec.

**Alternatives considered**: None — this is a hard TDLib requirement, not a design
choice.
