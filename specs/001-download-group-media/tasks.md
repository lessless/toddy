# Tasks: Download Group Media

**Input**: Design documents from `/specs/001-download-group-media/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/toddy_api.md, quickstart.md

**Tests**: Included and REQUIRED — the constitution mandates a full TDD (red-green-refactor)
cycle for all implementation, and Principle III requires every FFI-touching change to be
verified against a real, compiled TDLib build, not mocks alone. Each phase below therefore
writes failing tests before the implementation that makes them pass.

**Organization**: Tasks are grouped by user story (spec.md priorities P1/P2/P3) to enable
independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)
- File paths below follow the single-project layout in plan.md's Project Structure

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [X] T001 Create project structure per plan.md: `mix new toddy --sup`, then create `lib/toddy/`, `lib/toddy/native/`, `src/`, `test/toddy/`, `test/integration/`
- [X] T002 Add `zigler ~> 0.16` and `jason` dependencies to `mix.exs` and configure the Zigler NIF module target (`lib/toddy/native/td_json.ex` → `src/td_json.zig`) (research.md R2)
- [X] T003 [P] Pin Elixir `~> 1.20` / OTP 27+ in `.tool-versions` (research.md R1)
- [X] T004 [P] Add `.formatter.exs` formatting configuration
- [X] T005 [P] Document `libtdjson` acquisition and `api_id`/`api_hash` prerequisites in `README.md` (research.md R3, R10)

**Checkpoint**: `mix compile` succeeds on an empty project skeleton.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The generic TDLib request/response engine, native NIF, shared types, and
observability probes every user story depends on.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T006 [P] Write failing integration test for a native round-trip (create → execute a synchronous `getOption "version"` call → send/receive → destroy) against a real `libtdjson` in `test/integration/native_integration_test.exs` (Constitution Principle III)
- [X] T007 Implement Zig NIF `src/td_json.zig` wrapping `td_json_client_create/send/receive/execute/destroy` to make T006 pass (Constitution Principles I, VI; research.md R4)
- [X] T008 Implement `lib/toddy/native/td_json.ex` Zigler module: dirty-scheduler wiring for the blocking receive/execute calls, converting Zig errors to `{:error, reason}` (Constitution Principle I; research.md R2)
- [X] T009 [P] Define public structs in `lib/toddy/types.ex`: `Group`, `Message`, `MediaItem`, `Download` (data-model.md)
- [X] T010 [P] Implement `lib/toddy/probes.ex` with all Domain Probe functions from `contracts/toddy_api.md` (Constitution Principle VII)
- [X] T011 [P] Write failing unit test for `@extra`-based request/response correlation and unsolicited-update dispatch in `test/toddy/session_correlation_test.exs` (research.md R5)
- [X] T012 [P] Write failing unit test for flood-wait retry-after parsing and transparent retry in `test/toddy/session_flood_wait_test.exs` (FR-013; research.md R9)
- [X] T013 Implement `lib/toddy/session.ex` GenServer core to make T011/T012 pass: native client lifecycle, session directory created `0700` (FR-002; research.md R6), `@extra` correlation engine, receive-loop update dispatch, flood-wait handling (depends on T008, T009, T010, T011, T012)

**Checkpoint**: Foundation ready — user story implementation can now begin.

---

## Phase 3: User Story 1 - Authenticate a Telegram Account (Priority: P1) 🎯 MVP

**Goal**: A developer authenticates a personal Telegram account and ends up with a
reusable, authenticated connection (FR-001, FR-002).

**Independent Test**: Run the authentication flow with a real account's credentials;
confirm a second, later run against the same session directory reconnects to `:ready`
without prompting for the verification code again (SC-001, SC-002).

### Tests for User Story 1

- [X] T014 [P] [US1] Write failing unit test for auth state transitions (`:unauthenticated → :wait_code → [:wait_password] → :ready`) with mocked TDLib responses in `test/toddy/session_test.exs`
- [X] T015 [P] [US1] Write failing integration test for the full auth flow plus reconnect-without-reauth against real `libtdjson` in `test/integration/session_integration_test.exs` (Constitution Principle III; quickstart.md step 1)

### Implementation for User Story 1

- [X] T016 [US1] Implement `Toddy.Session.start_link/1` and `status/1` in `lib/toddy/session.ex` (depends on T013, T014, T015)
- [X] T017 [US1] Implement `Toddy.Session.submit_code/2` and `submit_password/2`, mapping TDLib `authorizationState` updates to `auth_state` (depends on T016)
- [X] T018 [US1] Enforce `0600` permissions on TDLib's session files after each auth-affecting operation in `lib/toddy/session.ex` (FR-002; research.md R6) (depends on T017)
- [X] T019 [US1] Wire `Toddy.Probes.session_authenticated/1` on reaching `:ready` in `lib/toddy/session.ex` (Constitution Principle VII) (depends on T017)

**Checkpoint**: User Story 1 is fully functional and independently testable (MVP).

---

## Phase 4: User Story 2 - Find Media in a Group (Priority: P2)

**Goal**: Given an authenticated session, locate a specific group and list its
media-bearing messages (FR-003, FR-004, FR-005).

**Independent Test**: Given an already-authenticated session, point at a known group
and confirm it returns exactly the messages that carry media (SC-003); a group
identifier the account doesn't belong to returns a clear not-found error, not an
empty result.

### Tests for User Story 2

- [X] T020 [P] [US2] Write failing unit test for group resolution plus history pagination and media-type filtering with mocked responses in `test/toddy/group_test.exs`
- [X] T021 [P] [US2] Write failing integration test for `Toddy.Group.find/2` and `list_media/2` against real `libtdjson`/a test account in `test/integration/group_integration_test.exs`

### Implementation for User Story 2

- [X] T022 [US2] Implement `Toddy.Group.find/2` (resolve by ID or exact title; `{:error, :group_not_found}` otherwise) in `lib/toddy/group.ex` (depends on T013, T020, T021)
- [X] T023 [US2] Implement `Toddy.Group.list_media/2`: `getChatHistory` pagination plus content-type filtering for photo/video/document/audio/voice (research.md R7) in `lib/toddy/group.ex` (depends on T022)
- [X] T024 [US2] Wire `Toddy.Probes.group_not_found/1` in `lib/toddy/group.ex` (Constitution Principle VII) (depends on T022)

**Checkpoint**: User Stories 1 and 2 both work independently.

---

## Phase 5: User Story 3 - Download Group Media (Priority: P3)

**Goal**: Given identified media messages, download them reliably to a caller-chosen
destination — deduplicated, size-verified, retried on transient failure, with clear
per-item status (FR-006–FR-011).

**Independent Test**: Given a list of already-identified media messages, trigger
downloads and confirm files land on disk with the expected size (SC-004); a repeat
request produces no duplicate files (SC-006); a single unavailable item fails
distinguishably without aborting the rest of the batch (US3 acceptance scenario 4).

### Tests for User Story 3

- [X] T025 [P] [US3] Write failing unit test for dedup-by-`remote_file_id` skip logic in `test/toddy/download_dedup_test.exs` (FR-007, SC-006)
- [X] T026 [P] [US3] Write failing unit test for size verification plus bounded transient-failure retry in `test/toddy/download_retry_test.exs` (FR-008, FR-009, SC-004, SC-005)
- [X] T027 [P] [US3] Write failing integration test for `fetch/3`/`fetch_all/3` against real `libtdjson`/a test account: completed files on disk, duplicate skip, distinguishable failure without aborting the batch in `test/integration/download_integration_test.exs` (FR-006, FR-010; US3 acceptance scenario 4)

### Implementation for User Story 3

- [X] T028 [US3] Implement `Toddy.Download.fetch/3`: `downloadFile` → wait for `updateFile` completion → copy to `destination_path` → verify size (research.md R8) in `lib/toddy/download.ex` (depends on T013, T025, T026, T027)
- [X] T029 [US3] Implement dedup short-circuit keyed on `remote_file_id` + `destination_path` in `lib/toddy/download.ex` (FR-007, SC-006) (depends on T028)
- [X] T030 [US3] Implement bounded transient-failure retry in `lib/toddy/download.ex` (FR-009) (depends on T028)
- [X] T031 [US3] Implement `Toddy.Download.fetch_all/3` batch driver: continue past individual failures and aggregate results (FR-010, FR-011) in `lib/toddy/download.ex` (depends on T028, T029, T030)
- [X] T032 [US3] Wire `Toddy.Probes.download_started/2`, `download_completed/2`, `download_failed/2` in `lib/toddy/download.ex` (Constitution Principle VII) (depends on T028)

**Checkpoint**: All three user stories are independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Ties the three stories together into a coherent, documented, CI-verified package.

- [X] T033 Implement `lib/toddy.ex` module documentation and top-level facade referencing `Toddy.Session`/`Group`/`Download` (plan.md Project Structure) (depends on T019, T024, T032)
- [X] T034 [P] Add `@doc`/`@spec` to every public function in `lib/toddy/session.ex`, `group.ex`, `download.ex`, `probes.ex` matching `contracts/toddy_api.md` exactly (depends on T019, T024, T032)
- [X] T035 [P] Add a CI workflow running `mix test` (unit) and a separate `mix test --only integration` job against a built `libtdjson` in `.github/workflows/ci.yml` (Constitution Principle III, Development Workflow) (depends on T019, T024, T032)
- [X] T036 [P] Expand `README.md` with the full `quickstart.md` walkthrough (depends on T005)
- [ ] T037 Run `quickstart.md` end-to-end against a real test account and confirm all three steps' expected outcomes (depends on T033)
  - **Status**: partially unblocked. Step 1 (authenticate) is now confirmed working against
    live Telegram infrastructure — `Toddy.Session` reaches `:wait_code` with real credentials.
    Getting here required finding and fixing three real bugs, not guesses (see research.md
    R3/R4/R8 addenda): `setTdlibParameters`'s nested-vs-flat field structure changed between
    TDLib versions (the actual root cause of the `"Valid api_id must be provided"` failures —
    not a credential problem, confirmed by reproducing it with a well-known non-secret
    `api_id` too), a missing `authorizationStateWaitEncryptionKey` handler, and Homebrew's
    stable `tdlib` package being too old for Telegram's servers to accept login from at all.
    Now pinned to a verified working commit (`022d602`, see README/CI).
    Steps 2–3 (find group, download media) still need `TG_TEST_CODE` (the live login code,
    supplied per-run — see README) and `TG_TEST_GROUP` (a real group you're in) to exercise
    against live data: `TG_TEST_CODE=<code> fnox exec -- mix test --include integration`.
- [X] T038 [P] Verify `mix format` and `zig fmt` pass cleanly across the codebase (Constitution Development Workflow) (depends on T033)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately.
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories.
- **User Stories (Phase 3–5)**: All depend on Foundational completion; the three
  stories are independent of each other and may proceed in parallel or in priority
  order (P1 → P2 → P3).
- **Polish (Phase 6)**: Depends on all three user stories being complete.

### User Story Dependencies

- **User Story 1 (P1)**: No dependency on US2/US3 — this is the MVP slice.
- **User Story 2 (P2)**: Uses the Foundational session engine (T013) directly, not
  US1's auth-specific code; independently testable given any `:ready` session.
- **User Story 3 (P3)**: Same — depends on Foundational (T013), not on US1/US2 code.

### Within Each Phase

- Failing tests are written before the implementation task(s) that make them pass
  (constitution-mandated TDD).
- Within Foundational/US3, model/type tasks precede the service logic that uses them.

### Parallel Opportunities

- Setup: T003, T004, T005 (after T001).
- Foundational: T006 (test) run alongside T009, T010, T011, T012 (different files);
  T007→T008 and T013 are sequential (they build on the tests/pieces above).
- Each user story's two-or-three test tasks (T014/T015, T020/T021, T025/T026/T027) are
  parallel with each other (different files).
- Once Foundational (T013) is done, US1, US2, and US3 phases can be staffed and
  worked in parallel by different contributors.
- Polish: T034, T035, T036, T038 are parallel (different files); T033 and T037 are
  each their own sequential step.

---

## Parallel Example: Foundational Phase

```bash
# After T001/T002 (project + deps exist), launch together:
Task: "Write failing integration test for native round-trip in test/integration/native_integration_test.exs"
Task: "Define public structs in lib/toddy/types.ex"
Task: "Implement lib/toddy/probes.ex with Domain Probe functions"
Task: "Write failing unit test for @extra correlation in test/toddy/session_correlation_test.exs"
Task: "Write failing unit test for flood-wait retry in test/toddy/session_flood_wait_test.exs"
```

## Parallel Example: User Story 3

```bash
# Launch all three US3 test tasks together:
Task: "Write failing unit test for dedup skip logic in test/toddy/download_dedup_test.exs"
Task: "Write failing unit test for size verification + retry in test/toddy/download_retry_test.exs"
Task: "Write failing integration test for fetch/3+fetch_all/3 in test/integration/download_integration_test.exs"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup.
2. Complete Phase 2: Foundational (CRITICAL — blocks all stories).
3. Complete Phase 3: User Story 1.
4. **STOP and VALIDATE**: run quickstart.md step 1 against a real account; confirm
   SC-001/SC-002.
5. At this point you have a reusable, authenticated TDLib session — a demonstrable
   increment even without group/download capability.

### Incremental Delivery

1. Setup + Foundational → generic TDLib request engine ready.
2. Add User Story 1 → validate independently → MVP.
3. Add User Story 2 → validate independently (find a group, list its media).
4. Add User Story 3 → validate independently (download the media found in step 3).
5. Polish → facade module, docs, CI, formatting.

### Parallel Team Strategy

With multiple contributors: complete Setup + Foundational together first (it blocks
everything); then split US1/US2/US3 across contributors, since none of the three
depends on another's implementation — only on the shared Foundational session engine.

---

## Notes

- [P] tasks touch different files and have no dependency on an incomplete task.
- [Story] labels map each task to its user story for traceability back to spec.md.
- Every implementation task is preceded by the failing test(s) it must satisfy.
- FR-013 (flood-wait) lives in Foundational (T013), not User Story 3, because it is
  generic to every TDLib request — including User Story 1's authentication calls —
  not specific to downloads. User Story 3 additionally implements a *separate*,
  download-specific bounded retry (T030) for ordinary transient network failures
  (FR-009), which is a distinct mechanism from flood-wait per research.md R9.
- Commit after each task or logical group; stop at any checkpoint to validate a story
  independently before continuing.
