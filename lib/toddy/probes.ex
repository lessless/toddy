defmodule Toddy.Probes do
  @moduledoc """
  Domain-Oriented Observability probes (Constitution Principle VII) that emit
  wide events / canonical log lines (Constitution Principle VIII) as
  OpenTelemetry spans.

  This is the only module in Toddy allowed to call `OpenTelemetry` directly.
  `Toddy.Session`, `Toddy.Group`, and `Toddy.Download` call these
  semantically-named functions instead — each unit-of-work (authenticating,
  finding a group, listing a group's media, downloading one file, downloading
  a batch) results in exactly ONE span here, not several scattered narrow
  log lines. Callers accumulate their own fields as plain Elixir state
  (GenServer state for `Toddy.Session`, an accumulator variable for
  `Toddy.Group`/`Toddy.Download`) and pass the complete field set to the
  matching function here once the operation concludes, which sets it all as
  span attributes and ends the span.

  A field whose value isn't natively a valid span attribute on its own (e.g.
  a list of maps) is converted — JSON-encoded into a string — rather than
  silently dropped.
  """

  require OpenTelemetry.Tracer, as: Tracer
  alias OpenTelemetry.Span

  @doc "Starts a wide event's span, named after the unit-of-work. Pass the result to a `finish_event/3`-based function below."
  def start_event(name), do: Tracer.start_span(name)

  @doc "Fires once a session reaches `:ready`."
  def session_authenticated(span_ctx, session_dir, auth_states_visited, auth_step_failures) do
    finish_event(span_ctx, %{
      outcome: :ready,
      session_dir: session_dir,
      auth_states_visited: auth_states_visited,
      auth_step_failures: Jason.encode!(auth_step_failures)
    })
  end

  @doc "Fires if a session reaches `:closed` without ever becoming `:ready`."
  def session_closed(span_ctx, session_dir, auth_states_visited, auth_step_failures) do
    finish_event(span_ctx, %{
      outcome: :closed,
      session_dir: session_dir,
      auth_states_visited: auth_states_visited,
      auth_step_failures: Jason.encode!(auth_step_failures)
    })
  end

  @doc "Fires when `Toddy.Group.find/2` resolves `identifier` to a real group."
  def group_found(span_ctx, identifier, group) do
    finish_event(span_ctx, %{
      outcome: :found,
      identifier: identifier,
      group_id: group.id,
      group_title: group.title
    })
  end

  @doc "Fires when `Toddy.Group.find/2` can't resolve `identifier` (FR-004)."
  def group_not_found(span_ctx, identifier) do
    finish_event(span_ctx, %{outcome: :not_found, identifier: identifier})
  end

  @doc "Fires when `Toddy.Group.list_media/2` finishes scanning a group's history."
  def group_media_listed(span_ctx, chat_id, media_count, pages_fetched) do
    finish_event(span_ctx, %{
      outcome: :ok,
      chat_id: chat_id,
      media_count: media_count,
      pages_fetched: pages_fetched
    })
  end

  @doc "Fires when a download is short-circuited by dedup (FR-007) — never reaches TDLib."
  def download_deduped(span_ctx, remote_file_id, destination_path) do
    finish_event(span_ctx, %{
      outcome: :deduped,
      remote_file_id: remote_file_id,
      destination_path: destination_path
    })
  end

  @doc "Fires when a download reaches `:completed` (FR-008)."
  def download_completed(span_ctx, remote_file_id, destination_path, bytes, retries_used) do
    finish_event(span_ctx, %{
      outcome: :completed,
      remote_file_id: remote_file_id,
      destination_path: destination_path,
      bytes: bytes,
      retries_used: retries_used
    })
  end

  @doc "Fires when a download reaches `:failed`, with a distinguishable `reason` (FR-010)."
  def download_failed(span_ctx, remote_file_id, destination_path, reason, retries_used) do
    finish_event(span_ctx, %{
      outcome: :failed,
      remote_file_id: remote_file_id,
      destination_path: destination_path,
      reason: inspect(reason),
      retries_used: retries_used
    })
  end

  @doc """
  Fires once per `Toddy.Download.fetch_all/4` call, summarizing every item in
  the batch as one wide event rather than one per download (those already got
  their own via `download_completed/5`/`download_failed/5`/`download_deduped/3`).
  """
  def download_batch_completed(span_ctx, downloads, group_by) do
    completed = Enum.count(downloads, &(&1.status == :completed))
    failed = Enum.count(downloads, &(&1.status == :failed))

    finish_event(span_ctx, %{
      outcome: if(failed == 0, do: :ok, else: :partial_failure),
      total: length(downloads),
      completed: completed,
      failed: failed,
      group_by: group_by || :none
    })
  end

  @doc "Fires when a TDLib flood-wait (429) is being waited out (FR-013) — instantaneous, standalone span."
  def rate_limited(retry_after_seconds) do
    :rate_limited
    |> start_event()
    |> finish_event(%{retry_after_seconds: retry_after_seconds})
  end

  defp finish_event(span_ctx, fields) do
    Span.set_attributes(span_ctx, fields)
    maybe_set_error_status(span_ctx, fields[:outcome])
    Span.end_span(span_ctx)
    :ok
  end

  defp maybe_set_error_status(span_ctx, outcome)
       when outcome in [:failed, :not_found, :partial_failure] do
    Span.set_status(span_ctx, :opentelemetry.status(:error, Atom.to_string(outcome)))
  end

  defp maybe_set_error_status(_span_ctx, _outcome), do: :ok
end
