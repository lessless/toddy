defmodule Toddy.Download do
  @moduledoc """
  Downloading identified media to a caller-chosen destination — deduplicated,
  size-verified, retried on transient failure (User Story 3 — FR-006–FR-011).

  Uses TDLib's `downloadFile` with `synchronous: true`, which blocks the
  request itself until the download completes and returns the finished file
  directly — simpler than polling `updateFile` pushes for the same guarantee,
  and requires no changes to the native layer (Constitution Principle VI).
  """

  alias Toddy.MediaItem
  alias Toddy.Message
  alias Toddy.Probes
  alias Toddy.Session

  @enforce_keys [:remote_file_id, :destination_path]
  defstruct [:remote_file_id, :destination_path, :error, status: :pending, bytes_downloaded: 0]

  @type status :: :pending | :in_progress | :completed | :failed

  @type t :: %__MODULE__{
          remote_file_id: String.t(),
          destination_path: String.t(),
          status: status(),
          error: atom() | {:tdlib_error, String.t()} | nil,
          bytes_downloaded: non_neg_integer()
        }

  @max_transient_retries 3
  @retry_backoff_ms 200
  @download_timeout 300_000

  @doc """
  Downloads one message's media to `destination_path`, blocking until the
  download reaches `:completed` or `:failed` (retries, including flood-wait,
  happen internally — FR-009, FR-013). Skips re-downloading if
  `destination_path` already holds the correctly-sized file (FR-007,
  SC-006). Always returns `{:ok, download}`, even on failure — check
  `download.status`/`download.error` rather than pattern-matching on the
  outer tuple.
  """
  def fetch(session, %Message{media: %MediaItem{} = media}, destination_path) do
    if already_downloaded?(media, destination_path) do
      {:ok, completed(media, destination_path)}
    else
      Probes.download_started(media.remote_file_id, destination_path)
      {:ok, do_fetch(session, media, destination_path, @max_transient_retries)}
    end
  end

  @doc """
  Batch entry point for User Story 3: downloads each message's media into
  `destination_dir` (named after `file_name`, falling back to
  `remote_file_id`), continuing past individual failures rather than
  aborting the batch (FR-010, FR-011).

  Pass `group_by: :date` to write each file into a `dd-mm-yyyy` subfolder
  named after that message's post date (`message.date`) instead of flat
  into `destination_dir`. Omitting it keeps the original flat layout.
  """
  def fetch_all(session, messages, destination_dir, opts \\ []) do
    group_by = Keyword.get(opts, :group_by)

    Enum.map(messages, fn %Message{media: media} = message ->
      destination_path = destination_path(destination_dir, message, media, group_by)
      {:ok, download} = fetch(session, message, destination_path)
      download
    end)
  end

  @doc "Accessor for a `Toddy.Download`'s current status."
  def status(%__MODULE__{status: status}), do: status

  defp destination_path(destination_dir, message, media, :date) do
    Path.join([destination_dir, Calendar.strftime(message.date, "%d-%m-%Y"), filename(media)])
  end

  defp destination_path(destination_dir, _message, media, _group_by) do
    Path.join(destination_dir, filename(media))
  end

  defp filename(media), do: media.file_name || media.remote_file_id

  # Internal: dedup, keyed on (remote_file_id, destination_path) per FR-007 —
  # the destination file's own presence/size is the dedup record, so this is
  # correct even across process restarts without any extra ledger.

  defp already_downloaded?(media, destination_path) do
    case File.stat(destination_path) do
      {:ok, %{size: size}} -> size == media.size
      _not_found_or_error -> false
    end
  end

  defp completed(media, destination_path) do
    %__MODULE__{
      remote_file_id: media.remote_file_id,
      destination_path: destination_path,
      status: :completed,
      bytes_downloaded: media.size
    }
  end

  # Internal: the actual downloadFile round-trip, with bounded retry on
  # server-side/transient failures (FR-009) — distinct from flood-wait
  # (FR-013), which Toddy.Session already handles generically for every
  # request, this one included.

  defp do_fetch(session, media, destination_path, retries_left) do
    request = %{
      "@type" => "downloadFile",
      "file_id" => media.file_id,
      "priority" => 1,
      "offset" => 0,
      "limit" => 0,
      "synchronous" => true
    }

    response = Session.request(session, request, @download_timeout)
    handle_response(response, session, media, destination_path, retries_left)
  catch
    :exit, _reason when retries_left > 0 ->
      Process.sleep(@retry_backoff_ms)
      do_fetch(session, media, destination_path, retries_left - 1)

    :exit, _reason ->
      fail(media, destination_path, :retries_exhausted)
  end

  defp handle_response(
         %{
           "@type" => "file",
           "local" => %{"path" => tmp_path, "is_downloading_completed" => true}
         },
         _session,
         media,
         destination_path,
         _retries_left
       ) do
    finalize(media, destination_path, tmp_path)
  end

  defp handle_response(
         %{"@type" => "error", "code" => code},
         session,
         media,
         destination_path,
         retries_left
       )
       when code >= 500 and retries_left > 0 do
    Process.sleep(@retry_backoff_ms)
    do_fetch(session, media, destination_path, retries_left - 1)
  end

  defp handle_response(
         %{"@type" => "error"} = error,
         _session,
         media,
         destination_path,
         _retries_left
       ) do
    fail(media, destination_path, error_reason(error))
  end

  defp handle_response(_other, _session, media, destination_path, _retries_left) do
    fail(media, destination_path, :unexpected_response)
  end

  defp finalize(media, destination_path, tmp_path) do
    File.mkdir_p!(Path.dirname(destination_path))
    expected_size = media.size

    with :ok <- File.cp(tmp_path, destination_path),
         {:ok, %{size: ^expected_size}} <- File.stat(destination_path) do
      Probes.download_completed(media.remote_file_id, media.size)

      %__MODULE__{
        remote_file_id: media.remote_file_id,
        destination_path: destination_path,
        status: :completed,
        bytes_downloaded: media.size
      }
    else
      {:ok, %{size: _mismatched_size}} -> fail(media, destination_path, :size_mismatch)
      {:error, posix_reason} -> fail(media, destination_path, posix_reason)
    end
  end

  defp fail(media, destination_path, reason) do
    Probes.download_failed(media.remote_file_id, reason)

    %__MODULE__{
      remote_file_id: media.remote_file_id,
      destination_path: destination_path,
      status: :failed,
      error: reason
    }
  end

  defp error_reason(%{"message" => message}) do
    cond do
      message =~ ~r/FILE_REFERENCE|FILE_ID_INVALID|not found/i -> :media_unavailable
      true -> {:tdlib_error, message}
    end
  end

  defp error_reason(_error), do: :unknown_error
end
