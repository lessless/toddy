defmodule Toddy.Probes do
  @moduledoc """
  Domain-Oriented Observability probes (Constitution Principle VII).

  This is the only module in Toddy allowed to call `Logger`/telemetry
  directly. `Toddy.Session`, `Toddy.Group`, and `Toddy.Download` call these
  semantically-named functions instead, so domain code stays readable in the
  language of the domain and observability behavior can be asserted on
  independently of the underlying logging/metrics technology.
  """

  require Logger

  @doc "Fires once a session reaches `:ready` (Constitution Principle VII)."
  def session_authenticated(session_dir) do
    Logger.info("toddy.session_authenticated", session_dir: session_dir)
    :ok
  end

  @doc """
  Fires on every TDLib `updateAuthorizationState` transition. `state_type` is
  the bare TDLib type name (e.g. `"authorizationStateWaitCode"`) — never the
  request/parameter payloads that carry credentials, so this is always safe
  to log at a verbose level even in production.
  """
  def auth_state_changed(state_type) do
    Logger.debug("toddy.auth_state_changed", state: state_type)
    :ok
  end

  @doc "Fires when `Toddy.Group.find/2` can't resolve `identifier` (FR-004)."
  def group_not_found(identifier) do
    Logger.warning("toddy.group_not_found", identifier: identifier)
    :ok
  end

  @doc "Fires when a download actually starts (not short-circuited by dedup)."
  def download_started(remote_file_id, destination_path) do
    Logger.debug("toddy.download_started",
      remote_file_id: remote_file_id,
      destination_path: destination_path
    )

    :ok
  end

  @doc "Fires when a download reaches `:completed` (FR-008)."
  def download_completed(remote_file_id, bytes) do
    Logger.info("toddy.download_completed", remote_file_id: remote_file_id, bytes: bytes)
    :ok
  end

  @doc "Fires when a download reaches `:failed`, with a distinguishable `reason` (FR-010)."
  def download_failed(remote_file_id, reason) do
    Logger.warning("toddy.download_failed", remote_file_id: remote_file_id, reason: reason)
    :ok
  end

  @doc "Fires when a TDLib flood-wait (429) is being waited out (FR-013)."
  def rate_limited(retry_after_seconds) do
    Logger.debug("toddy.rate_limited", retry_after_seconds: retry_after_seconds)
    :ok
  end

  @doc """
  Fires when TDLib returns an error for a request the session driver fired
  automatically as part of the login handshake (setTdlibParameters,
  checkDatabaseEncryptionKey, setAuthenticationPhoneNumber) — these aren't
  correlated back to a waiting caller, so without this they'd fail silently.
  """
  def auth_step_failed(request_type, code, message) do
    Logger.warning("toddy.auth_step_failed",
      request_type: request_type,
      code: code,
      message: message
    )

    :ok
  end
end
