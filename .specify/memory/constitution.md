<!--
Sync Impact Report
- Version change: [TEMPLATE] → 1.0.0 (initial ratification)
- Modified principles: n/a (first concrete adoption; all five slots filled for the first time)
  - [PRINCIPLE_1_NAME] → I. NIF Safety & BEAM Stability (NON-NEGOTIABLE)
  - [PRINCIPLE_2_NAME] → II. Idiomatic Elixir Surface
  - [PRINCIPLE_3_NAME] → III. Verify Against Real TDLib (Integration-Test-First)
  - [PRINCIPLE_4_NAME] → IV. Reproducible Native Builds
  - [PRINCIPLE_5_NAME] → V. Track TDLib Compatibility via Semver
- Added sections: Technology & Native Dependencies; Development Workflow; Governance (amendment
  procedure, versioning policy, compliance review)
- Removed sections: none
- Templates requiring follow-up: none checked in this run (scope of this command is the
  constitution file only; dependent templates/commands read this file at runtime)
- Deferred placeholders: none — RATIFICATION_DATE set to the date of this initial adoption
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
by the project maintainer.
When implementing follow full TDD cycle governed by Kent Beck  Simple Design rules
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

**Version**: 1.0.0 | **Ratified**: 2026-08-21 | **Last Amended**: 2026-08-21
