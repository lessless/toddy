defmodule Toddy.Probes do
  @moduledoc """
  Domain-Oriented Observability probes (Constitution Principle VII) that emit
  wide events / canonical log lines (Constitution Principle VIII).

  This is the only module in Toddy allowed to call `Logger`/telemetry
  directly. `Toddy.Session`, `Toddy.Group`, and `Toddy.Download` call these
  semantically-named functions instead of Logger — and each unit-of-work
  (authenticating, finding a group, downloading a file, downloading a batch)
  results in exactly ONE consolidated log line here, not several scattered
  ones. Callers accumulate their own fields as plain Elixir state (GenServer
  state for `Toddy.Session`, an accumulator variable for `Toddy.Group`/
  `Toddy.Download`) and pass the complete field set to the matching function
  here once the operation concludes.

  The full field set is rendered directly into the log *message* (logfmt-style
  `key=value` pairs), not left in Logger metadata alone — Toddy is a library,
  not an application, so it doesn't control whether whatever consumes it has
  configured Logger to print custom metadata. Also passed as metadata for
  consumers with structured/JSON log backends that do read it.
  """

  require Logger

  @doc "Starts timing a unit-of-work. Pass the result to a `finish_event/3`-based function below."
  def start_event, do: System.monotonic_time(:millisecond)

  @doc "Fires once a session reaches `:ready`."
  def session_authenticated(started_at, session_dir, auth_states_visited, auth_step_failures) do
    finish_event(started_at, :session_authenticate, %{
      outcome: :ready,
      session_dir: session_dir,
      auth_states_visited: auth_states_visited,
      auth_step_failures: auth_step_failures
    })
  end

  @doc "Fires if a session reaches `:closed` without ever becoming `:ready`."
  def session_closed(started_at, session_dir, auth_states_visited, auth_step_failures) do
    finish_event(started_at, :session_authenticate, %{
      outcome: :closed,
      session_dir: session_dir,
      auth_states_visited: auth_states_visited,
      auth_step_failures: auth_step_failures
    })
  end

  @doc "Fires when `Toddy.Group.find/2` resolves `identifier` to a real group."
  def group_found(started_at, identifier, group) do
    finish_event(started_at, :group_find, %{
      outcome: :found,
      identifier: identifier,
      group_id: group.id,
      group_title: group.title
    })
  end

  @doc "Fires when `Toddy.Group.find/2` can't resolve `identifier` (FR-004)."
  def group_not_found(started_at, identifier) do
    finish_event(started_at, :group_find, %{outcome: :not_found, identifier: identifier})
  end

  @doc "Fires when `Toddy.Group.list_media/2` finishes scanning a group's history."
  def group_media_listed(started_at, chat_id, media_count, pages_fetched) do
    finish_event(started_at, :group_list_media, %{
      outcome: :ok,
      chat_id: chat_id,
      media_count: media_count,
      pages_fetched: pages_fetched
    })
  end

  @doc "Fires when a download is short-circuited by dedup (FR-007) — never reaches TDLib."
  def download_deduped(started_at, remote_file_id, destination_path) do
    finish_event(started_at, :download, %{
      outcome: :deduped,
      remote_file_id: remote_file_id,
      destination_path: destination_path
    })
  end

  @doc "Fires when a download reaches `:completed` (FR-008)."
  def download_completed(started_at, remote_file_id, destination_path, bytes, retries_used) do
    finish_event(started_at, :download, %{
      outcome: :completed,
      remote_file_id: remote_file_id,
      destination_path: destination_path,
      bytes: bytes,
      retries_used: retries_used
    })
  end

  @doc "Fires when a download reaches `:failed`, with a distinguishable `reason` (FR-010)."
  def download_failed(started_at, remote_file_id, destination_path, reason, retries_used) do
    finish_event(started_at, :download, %{
      outcome: :failed,
      remote_file_id: remote_file_id,
      destination_path: destination_path,
      reason: reason,
      retries_used: retries_used
    })
  end

  @doc """
  Fires once per `Toddy.Download.fetch_all/4` call, summarizing every item in
  the batch as one wide event rather than one per download (those already got
  their own via `download_completed/5`/`download_failed/5`/`download_deduped/3`).
  """
  def download_batch_completed(started_at, downloads, group_by) do
    completed = Enum.count(downloads, &(&1.status == :completed))
    failed = Enum.count(downloads, &(&1.status == :failed))

    finish_event(started_at, :download_batch, %{
      outcome: if(failed == 0, do: :ok, else: :partial_failure),
      total: length(downloads),
      completed: completed,
      failed: failed,
      group_by: group_by || :none
    })
  end

  @doc "Fires when a TDLib flood-wait (429) is being waited out (FR-013) — instantaneous, no matching start."
  def rate_limited(retry_after_seconds) do
    emit(:info, :rate_limited, %{retry_after_seconds: retry_after_seconds})
  end

  defp finish_event(started_at, name, fields) do
    duration_ms = System.monotonic_time(:millisecond) - started_at
    level = level_for(fields[:outcome])
    emit(level, name, Map.put(fields, :duration_ms, duration_ms))
  end

  defp level_for(outcome) when outcome in [:failed, :not_found, :partial_failure], do: :warning
  defp level_for(_outcome), do: :info

  defp emit(level, name, fields) do
    message = "toddy.wide_event " <> format_fields(Map.put(fields, :event, name))
    Logger.log(level, message, Map.to_list(fields) ++ [event: name])
    :ok
  end

  defp format_fields(fields) do
    # `event` first, then everything else, for a consistent skim order —
    # duration_ms right after it since it's almost always the next thing read.
    ordered_keys =
      [:event, :duration_ms, :outcome] ++ (Map.keys(fields) -- [:event, :duration_ms, :outcome])

    ordered_keys
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(fields, &1))
    |> Enum.map_join(" ", fn key -> "#{key}=#{format_value(fields[key])}" end)
  end

  defp format_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp format_value(value) when is_binary(value), do: inspect(value)
  defp format_value(value), do: inspect(value)
end
