<!--
Sync Impact Report
- Version change: 1.2.0 → 1.3.0
- Modified principles: none renamed or redefined
- Added principles:
  - VIII. Wide Events (Canonical Log Lines) (new)
- Added sections: none (principle added within existing Core Principles section)
- Expanded sections: Development Workflow — added a PR-justification rule enforcing
  Principle VIII (narrow, scattered log lines for one unit-of-work instead of one
  consolidated wide event)
- Removed sections: none
- Templates requiring follow-up: none checked in this run (scope of this command is
  the constitution file only; dependent templates/commands read this file at runtime)
- Deferred placeholders: none
-->

# Toddy Constitution

## Core Principles

### I. NIF Safety & BEAM Stability (NON-NEGOTIABLE)
All Zig/Zigler NIF code MUST NOT crash, panic, or block the BEAM VM. Any call into
`td` (TDLib) that may take non-trivial time MUST run on a dirty scheduler (dirty CPU
or dirty IO, as appropriate) rather than a normal scheduler. FFI boundary code MUST
catch and convert Zig errors into Elixir-visible `{:error, reason}` tuples instead of
allowing panics or segfaults to propagate into the VM.
Rationale: a NIF crash takes down the entire BEAM node, not just the calling process —
the availability guarantees Elixir/OTP is known for are only as strong as the weakest NIF.

### II. Idiomatic Elixir Surface
The public API MUST present idiomatic Elixir constructs — structs, `{:ok, result}` /
`{:error, reason}` tuples, pattern-matchable messages, GenServer-based clients — and
MUST NOT leak raw TDLib JSON payloads, C pointers, or Zig-specific types to callers.
Rationale: consumers of this library should be able to write ordinary Elixir/OTP code
without needing to understand TDLib's C API or the Zig FFI layer underneath it.

### III. Verify Against Real TDLib (Integration-Test-First)
Every feature or bug fix that touches the FFI boundary MUST be verified against a real,
compiled TDLib (`libtdjson`) build in integration tests before it is considered done.
Mocked or stubbed TDLib responses alone are NOT sufficient to merge FFI-facing changes.
Rationale: TDLib's behavior (async update ordering, error codes, JSON payload shapes)
is complex and under-documented upstream; only exercising the real library catches
protocol drift and platform-specific breakage.

### IV. Reproducible Native Builds
The Zig toolchain version, the Zigler version, and the TDLib (`td`) version/commit this
project builds against MUST be pinned and documented, and the native build MUST succeed
from a clean checkout via the project's standard build command.
Rationale: this project's correctness is inseparable from the exact native library it
links against; unpinned toolchain or library versions produce silent, hard-to-reproduce
breakage across contributors' machines and CI.

### V. Track TDLib Compatibility via Semver
Changes to the Elixir-facing API MUST use semantic versioning. Any change driven by a
breaking change in the upstream TDLib API MUST be called out explicitly in the changelog
and MUST bump at least the MINOR version (MAJOR if the wrapper's own public API breaks
as a result).
Rationale: consumers pin this library expecting stability; upstream TDLib churn must
never silently become an undocumented breaking change downstream.

### VI. Elixir-First, Minimal Native Surface
As much of the system's logic as possible MUST live in Elixir. The Zig/Zigler layer
MUST be kept as thin as possible — limited to marshaling data across the FFI boundary
(encoding requests for `td` and decoding its responses/updates) rather than containing
parsing, validation, business logic, orchestration, retries, or rate-limit handling,
all of which MUST be implemented in Elixir instead.
Rationale: Zig code sits below the BEAM's safety net (Principle I) and is harder to
test, debug, and reason about than Elixir; keeping it minimal shrinks the surface area
where a mistake can crash the VM and keeps the bulk of the system testable with
ordinary Elixir tooling.

### VII. Domain-Oriented Observability (Domain Probes)
Domain/business-logic code MUST NOT call logging, metrics, or telemetry libraries
directly. It MUST instead call semantically-named "probe" functions or modules named
after business events (e.g. `session_authenticated`, `group_not_found`,
`download_started`, `download_completed`, `download_failed`, `rate_limited`) that
encapsulate the actual instrumentation technology behind them.
Rationale: this keeps domain code readable in the language of the domain instead of
littered with logging/metrics calls, keeps the underlying instrumentation technology
swappable and centralized in one place, and makes observability behavior independently
testable — asserting that the right domain events fired, rather than that a specific
log line was printed. It complements Principle VI: probes are domain-facing Elixir
code, not something that belongs in the Zig layer.

### VIII. Wide Events (Canonical Log Lines)
For each unit-of-work (authenticating a session, finding a group, listing a group's
media, downloading one media item, downloading a batch), the system MUST emit exactly
ONE consolidated, structured log event containing every relevant field collected
during that operation (identifiers, outcome, duration, counts, failure reasons, etc.)
— not many small scattered narrow log lines for the same operation. Domain code still
only ever calls `Toddy.Probes` (Principle VII) — what changes is that probes MUST
accumulate fields onto the current operation's wide event as things happen (e.g. auth
state transitions, retries encountered) and emit a single consolidated record when the
operation concludes, rather than logging each field as its own line immediately. Wide
events MUST be tagged/named consistently (a fixed log message such as
`"toddy.wide_event"` with an `event` field naming the operation) so they are trivially
filterable as a distinct category from other log output.
Rationale: scattered narrow logs force a reader to manually reassemble what happened
during one operation by correlating many separate lines; a single wide event per
unit-of-work makes each operation queryable and diffable as one record, which is what
actually makes rare-condition debugging and cross-operation comparison tractable (see
Jeremy Morrell, "A Practitioner's Guide to Wide Events",
https://jeremymorrell.dev/blog/a-practitioners-guide-to-wide-events/).

## Technology & Native Dependencies

Elixir/OTP is the host language; Zig, invoked through Zigler, provides the native
bindings; TDLib (`td`) is the wrapped native library. Required versions of the Zig
toolchain, Zigler, and TDLib MUST be documented in the project's build/setup
instructions and kept current with what CI actually builds against. Any new native
dependency introduced at the FFI boundary MUST be justified in the PR description and
documented alongside the existing native dependencies.

## Development Workflow

Any pull request that touches Zig code or the NIF boundary MUST be reviewed by someone
familiar with that FFI layer before merge. CI MUST run both the Elixir unit test suite
and the integration test suite against a real TDLib build before a change is merged.
Formatting checks (`mix format` for Elixir, `zig fmt` for Zig) MUST pass. Changes that
weaken NIF Safety (Principle I) or bypass real-TDLib verification (Principle III) MUST
NOT be merged regardless of urgency, without an explicit, documented exception approved
by the project maintainer. Changes that add Zig/native code where the same logic could
reasonably live in Elixir instead MUST justify that choice in the PR description
(Principle VI). Changes that call logging, metrics, or telemetry libraries directly
from domain code, bypassing a domain probe, MUST justify that choice in the PR
description (Principle VII). Changes that log the same unit-of-work as multiple
scattered narrow lines instead of one consolidated wide event MUST justify that choice
in the PR description (Principle VIII).

Implementation MUST follow a full test-driven development cycle (red-green-refactor),
guided by Kent Beck's Simple Design rules, rather than writing implementation code
ahead of a failing test.

## Governance

This constitution supersedes all other project practices and conventions. Amendments
require: (1) a documented rationale for the change, (2) an update to this file following
the Sync Impact Report format, and (3) a version bump per the policy below. All PRs and
code reviews MUST verify compliance with these principles; any deviation MUST be
explicitly justified in the PR description and, if it recurs, folded back into this
constitution rather than left as a standing exception.

Versioning policy (semantic versioning applied to this document):
- MAJOR: backward-incompatible governance changes — removing or redefining a principle.
- MINOR: adding a new principle or materially expanding existing guidance.
- PATCH: wording clarifications and non-semantic refinements.

Compliance is reviewed at each PR touching the FFI boundary, native build configuration,
or the public API, and revisited whenever TDLib is upgraded to a new pinned version.

**Version**: 1.3.0 | **Ratified**: 2026-08-21 | **Last Amended**: 2026-08-22
