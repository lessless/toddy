# Implementation Plan: Download Group Media

**Branch**: `001-download-group-media` | **Date**: 2026-08-21 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-download-group-media/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command; its definition describes the execution workflow.

## Summary

A minimal Elixir library that authenticates a personal Telegram account, locates a
group the account belongs to, and batch-downloads the existing media in that group's
message history to a local destination. TDLib is driven through its JSON interface
(`libtdjson`'s `td_json_client_*` C functions) via a thin Zig NIF; every other concern —
JSON encoding/decoding, request/response correlation, chat-history pagination, media
filtering, download orchestration, deduplication, retries, flood-wait handling, and
observability — is implemented in Elixir, per Constitution Principles VI and VII.

## Technical Context

**Language/Version**: Elixir ~> 1.20 (OTP 27+, tested against OTP 29) — exact patch
pinned in `.tool-versions` per Constitution Principle IV.

**Primary Dependencies**: `zigler` (~> 0.16, pairs with Zig 0.16.x) for the NIF; `jason`
for TDLib JSON payload encode/decode. No other runtime dependencies — this is
intentionally a minimal wrapper (Constitution Principle VI).

**Storage**: Local filesystem only. TDLib manages its own session/database directory
(passed in via `setTdlibParameters`); the wrapper restricts that directory to `0700`
and its files to `0600` (FR-002). Downloaded media is written to the destination path
the caller supplies (FR-006). No additional database is introduced.

**Testing**: ExUnit, split into `:unit` (pure Elixir logic against mocked TDLib
JSON responses) and `:integration` (real `libtdjson` build, exercised per Constitution
Principle III) via `mix test` / `mix test --only integration`.

**Target Platform**: Linux/macOS developer and server environments with an Elixir/OTP
runtime, a Zig toolchain (fetched by Zigler), and a built `libtdjson` shared library
available at compile and runtime.

**Project Type**: Library (Hex package) — single project structure.

**Performance Goals**: No hard latency target; the defining goal is unattended
completion (SC-005, SC-007) for groups up to ~20,000 messages (SC-008) without
manual intervention or redesign.

**Constraints**: Zig code limited to marshaling across the 5 `td_json_client` C
functions (Principle VI); every blocking TDLib call runs on a dirty scheduler
(Principle I); domain modules never call `Logger`/telemetry directly, only
`Toddy.Probes` (Principle VII); session files `0600`/`0700` (FR-002); TDLib flood-wait
responses are waited out automatically, not treated as failures (FR-013).

**Scale/Scope**: Single authenticated account, single target group per operation
(no multi-account/multi-group orchestration — see spec Assumptions); groups up to
~20,000 messages; 3 user stories, 13 functional requirements.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. NIF Safety & BEAM Stability | PASS | All `td_json_client_receive`/`_execute` calls run on `:dirty_io`; Zig side converts every error/unexpected condition to `{:error, reason}` instead of panicking (see research.md R3/R5). |
| II. Idiomatic Elixir Surface | PASS | Public API returns structs and `{:ok, _}`/`{:error, _}` tuples (data-model.md, contracts/toddy_api.md); raw TDLib JSON never crosses the public API boundary. |
| III. Verify Against Real TDLib | PASS | `:integration` ExUnit suite exercises a real compiled `libtdjson`; no FFI-facing change merges on mocks alone. |
| IV. Reproducible Native Builds | PASS | Elixir/Zig/Zigler versions pinned (research.md R1–R2); `libtdjson` acquisition pinned to a documented commit SHA (research.md R3). |
| V. Track TDLib Compatibility via Semver | PASS | No public release yet at plan stage; CHANGELOG + semver policy carried forward from the constitution, nothing in this design violates it. |
| VI. Elixir-First, Minimal Native Surface | PASS | Zig NIF is limited to `td_json_client_create/send/receive/execute/destroy` string marshaling (research.md R4); pagination, filtering, retries, dedup, flood-wait all in Elixir. |
| VII. Domain-Oriented Observability | PASS | `Toddy.Probes` is the sole call site for logging/telemetry; `Toddy.Session`/`Toddy.Group`/`Toddy.Download` call only probe functions (data-model.md). |

No violations identified. Complexity Tracking table below is not applicable.

## Project Structure

### Documentation (this feature)

```text
specs/001-download-group-media/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
│   └── toddy_api.md
└── tasks.md             # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
lib/
├── toddy.ex                    # Public API facade — delegates to domain modules
└── toddy/
    ├── session.ex               # GenServer: TDLib client lifecycle, auth flow (US1)
    ├── group.ex                 # Group lookup + media-message discovery (US2)
    ├── download.ex              # Download orchestration: dedup, retry, flood-wait (US3)
    ├── probes.ex                # Domain-Oriented Observability probes (Principle VII)
    ├── types.ex                 # Public structs: Group, Message, MediaItem, Download
    └── native/
        └── td_json.ex           # Zigler module: thin NIF over td_json_client_* (Principle VI)

src/
└── td_json.zig                  # Zig source backing lib/toddy/native/td_json.ex

test/
├── toddy/
│   ├── session_test.exs         # :unit — mocked TDLib JSON responses
│   ├── group_test.exs           # :unit
│   ├── download_test.exs        # :unit
│   └── probes_test.exs          # :unit — asserts domain events fire, not log format
└── integration/
    ├── session_integration_test.exs   # :integration — real libtdjson + test account
    ├── group_integration_test.exs     # :integration
    └── download_integration_test.exs  # :integration
```

**Structure Decision**: Single-project Elixir library layout (Option 1). `lib/toddy/`
holds all domain logic (Elixir-first per Principle VI); `lib/toddy/native/` plus
`src/td_json.zig` hold the entire native surface, kept intentionally small. Tests
are split by directory (`test/toddy/` vs `test/integration/`) rather than by ExUnit
tag alone, so the native-dependent suite is easy to locate and exclude in
environments without a built `libtdjson`.

## Complexity Tracking

> No Constitution Check violations were identified for this feature; this table is
> not applicable.
