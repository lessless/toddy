# Feature Specification: Download Group Media

**Feature Branch**: `001-download-group-media`

**Created**: 2026-08-21

**Status**: Draft

**Input**: User description: "Build robust, minimal tdlib wrapper for Elixir that would allow me to download media from a group that I'm member of. Only features necessary for that should be implemented."

## Clarifications

### Session 2026-08-21

- Q: How should the persisted Telegram session (which can fully control the account) be protected on local disk? → A: Restrict the session files to OS permissions readable only by the owning user (e.g., 0600/0700) — no additional encryption
- Q: What determines whether a media item counts as "already downloaded" and should be skipped? → A: Telegram's own unique remote file identifier for the media, matched regardless of local filename
- Q: When Telegram rate-limits the account (flood-wait) during a bulk download, should the system automatically wait out the delay and continue, or treat it like any other failure? → A: Automatically wait for the server-specified delay, then continue — treated as expected behavior, not a failure
- Q: What's the largest group (by message count) this wrapper needs to handle well? → A: Medium groups (up to ~20,000 messages) — typical active community group

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Authenticate a Telegram Account (Priority: P1)

A developer connects the library to their personal Telegram account (phone number,
verification code, and two-factor password if the account has one enabled) and ends
up with a reusable, authenticated connection that does not need to be re-established
from scratch on every run.

**Why this priority**: Nothing else is possible without an authenticated connection —
this is the foundation every other capability depends on.

**Independent Test**: Can be fully tested by running the authentication flow with a
real account's credentials and confirming that a second, later run reuses the saved
session without prompting for the verification code again. Delivers a working,
reusable Telegram connection on its own, independent of any group or download logic.

**Acceptance Scenarios**:

1. **Given** valid phone number and verification code, **When** the developer starts
   authentication, **Then** the connection becomes authenticated and ready to use.
2. **Given** an account with two-factor authentication enabled, **When** the correct
   password is supplied after the verification code, **Then** authentication succeeds.
3. **Given** a previously authenticated session, **When** the connection is started
   again, **Then** it reconnects without requiring the verification code to be re-entered.

---

### User Story 2 - Find Media in a Group (Priority: P2)

Using an authenticated connection, the developer specifies a group they belong to
(by its identifier or exact title) and receives the set of messages in that group
that have a media attachment.

**Why this priority**: Before anything can be downloaded, the library must be able to
reliably locate the target group and identify which of its messages actually contain
media — this is the step that turns "a group" into "a concrete list of things to fetch."

**Independent Test**: Can be fully tested, given an already-authenticated session, by
pointing the tool at a known group and confirming it returns the correct set of
media-bearing messages. Delivers visibility into what is downloadable, independent of
whether the download step itself works yet.

**Acceptance Scenarios**:

1. **Given** an authenticated connection and the title or ID of a group the account
   belongs to, **When** the developer requests its media messages, **Then** the
   library returns every message in that group that has an attached photo, video,
   document, or audio/voice attachment.
2. **Given** a group identifier that does not correspond to a group the account is a
   member of, **When** the developer requests its media messages, **Then** the
   library reports a clear "group not found / not a member" error instead of an
   empty or misleading result.

---

### User Story 3 - Download Group Media (Priority: P3)

Given one or more identified media messages, the developer triggers a download and
ends up with the corresponding files saved to a local destination they control, with
enough status information to know which downloads succeeded, which failed, and why.

**Why this priority**: This is the actual end goal of the feature — having the media
files on local storage — but it depends on the previous two stories to have an
authenticated connection and a concrete list of media to fetch.

**Independent Test**: Can be fully tested, given a list of already-identified media
messages, by triggering downloads and confirming the files land on local disk with
the expected content and size. Delivers the feature's core value independent of how
the messages were originally found.

**Acceptance Scenarios**:

1. **Given** a media message and a local destination, **When** the developer starts
   the download, **Then** the file is written to that destination and its size on
   disk matches the size reported for the media.
2. **Given** a media item that was already fully downloaded to the same destination,
   **When** the developer requests it again, **Then** the library skips re-downloading
   it instead of writing a duplicate.
3. **Given** a download that is interrupted by a transient network failure, **When**
   the interruption clears, **Then** the library automatically retries and completes
   the download without the developer having to restart the whole batch.
4. **Given** a media item that is no longer available on Telegram's servers, **When**
   the developer attempts to download it, **Then** the library reports a clear failure
   for that item without aborting downloads of the other requested items.

---

### Edge Cases

- What happens when the account requires two-factor (cloud password) verification
  during login, or the password supplied is wrong?
- What happens when the specified group does not exist, or the account is not (or is
  no longer) a member of it?
- What happens when a message's media has been deleted from Telegram's servers before
  it can be downloaded?
- What happens when a download is interrupted partway through by a network failure?
- What happens when local storage runs out of space, or the destination path is not
  writable?
- When Telegram temporarily rate-limits the account (flood control) during a bulk
  download of many media items, the system automatically waits out the
  server-specified delay and continues (see FR-013).
- What happens when the same media item is requested for download more than once?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST let a developer authenticate a single personal Telegram
  account using a phone number, a verification code, and — if the account has it
  enabled — a two-factor password.
- **FR-002**: The system MUST persist the authenticated session so that reconnecting
  later does not require re-entering the verification code or password. Persisted
  session files MUST be restricted to file-system permissions readable only by the
  owning user (e.g., `0600`/`0700`); no additional encryption at rest is required.
- **FR-003**: The system MUST let the developer identify a specific group the
  authenticated account is a member of, by supplying the group's identifier or exact
  title.
- **FR-004**: The system MUST report a clear, distinguishable error when the requested
  group cannot be found or the account is not a member of it, rather than returning an
  empty or misleading result.
- **FR-005**: The system MUST retrieve the set of messages in an identified group that
  have an attached photo, video, document, or audio/voice attachment.
- **FR-006**: The system MUST let the developer download the media attachment of an
  identified message to a destination on local storage that the developer specifies.
- **FR-007**: The system MUST skip re-downloading a media item whose Telegram-assigned
  unique remote file identifier matches one that has already been fully downloaded to
  the same destination, regardless of the local filename.
- **FR-008**: The system MUST verify that a completed download's size on disk matches
  the size reported for that media item before treating the download as successful.
- **FR-009**: The system MUST automatically retry a download after a transient network
  interruption, up to a bounded number of attempts, before reporting that item as
  failed.
- **FR-010**: The system MUST report download failures (media no longer available,
  insufficient local storage, destination not writable, etc.) with enough detail for
  the developer to distinguish the cause.
- **FR-011**: The system MUST expose, for each requested media item, whether its
  download is in progress, completed, or failed, so the developer can track a batch of
  downloads.
- **FR-012**: The system MUST scope media discovery and download to a group's existing
  message history as of the time of the request. Detecting or downloading media from
  messages that arrive after a request has started is out of scope for this feature.
- **FR-013**: The system MUST, when Telegram responds with a rate-limit (flood-wait)
  signal during a media listing or download request, automatically wait for the
  server-specified delay and then continue, rather than treating it as a failure.

### Key Entities

- **Telegram Account (Session)**: The authenticated connection between the library and
  a single personal Telegram account; tracks authentication status and holds the
  persisted session data that allows reconnecting without repeating verification.
- **Group**: A Telegram group chat the authenticated account is a member of;
  identified by an ID and a title; contains messages.
- **Message**: An item in a group's history; has a timestamp and sender, and may carry
  an attached Media Item.
- **Media Item**: A file attached to a message — photo, video, document, or
  audio/voice attachment; has metadata (type, size, filename, and a Telegram-assigned
  unique remote file identifier) needed to fetch, verify, and de-duplicate its content.
- **Download**: The record of turning a Media Item into a local file — keyed by the
  Media Item's remote file identifier, with its destination path and whether it is in
  progress, completed, or failed.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A developer can go from supplying valid Telegram login credentials to
  having a reusable, authenticated connection in under 2 minutes, excluding time spent
  waiting for the verification code to arrive.
- **SC-002**: Reconnecting with a previously authenticated session requires zero
  re-entry of verification credentials.
- **SC-003**: For a group with 500 messages, a single request for its media messages
  correctly identifies at least 95% of the messages that actually contain media, with
  no false positives.
- **SC-004**: 100% of successfully completed downloads have a file size on disk that
  matches the size reported for the source media item.
- **SC-005**: At least 95% of downloads that experience a single transient network
  interruption still complete successfully without manual intervention.
- **SC-006**: Re-running a download request against media that was already fully
  downloaded produces zero duplicate files.
- **SC-007**: 100% of downloads paused by a Telegram rate-limit (flood-wait) response
  complete automatically once the required wait elapses, without manual intervention.
- **SC-008**: Media discovery and download complete reliably, without redesign or
  manual intervention beyond the normal flow, for groups containing up to 20,000
  messages.

## Assumptions

- The authenticated account is the developer's own personal Telegram user account
  (not a bot account), matching "a group that I'm a member of."
- "Group" refers to a Telegram group chat (basic group or supergroup); broadcast
  channels are out of scope unless a future feature explicitly extends to them.
- "Media" covers photos, videos, documents, and audio/voice attachments, treated
  uniformly for the purposes of discovery and download.
- The library handles exactly one authenticated account and one target group per
  operation; multi-account or multi-group orchestration is out of scope for this
  minimal wrapper.
- The developer supplies and controls the local destination path for downloads; the
  library does not manage a media library, catalog, or viewer beyond writing files to
  that destination.
- No message-sending, chat-management (create/leave/delete group), or upload
  capabilities are in scope — this feature is read/download-only.
- Media discovery and download operate as a one-shot batch scan of a group's existing
  message history at request time; continuously watching for and downloading media
  from new incoming messages is out of scope for this feature.
- Target groups contain up to roughly 20,000 messages (a typical active community
  group); reliably handling substantially larger groups is out of scope for this
  minimal wrapper.
