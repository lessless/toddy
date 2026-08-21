defmodule Toddy.DownloadRetryTest do
  @moduledoc """
  User Story 3: size verification and bounded transient-failure retry
  (FR-008, FR-009, SC-004, SC-005) — distinct from flood-wait (FR-013),
  which Toddy.Session already handles generically for every request.
  """
  use ExUnit.Case, async: false
  import Mox
  import ExUnit.CaptureLog

  alias Toddy.Download
  alias Toddy.MediaItem
  alias Toddy.Message
  alias Toddy.Native.Mock

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    dir = Path.join(System.tmp_dir!(), "toddy_retry_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp media, do: %MediaItem{remote_file_id: "unique-1", file_id: 1, type: :photo, size: 9}
  defp message, do: %Message{id: 1, chat_id: 1, date: DateTime.utc_now(), media: media()}

  defp start_session(dir, responder) do
    Mock
    |> stub(:create, fn -> make_ref() end)
    |> stub(:receive, fn _h, _t ->
      Process.sleep(5)
      nil
    end)
    |> stub(:send, fn _handle, payload ->
      decoded = Jason.decode!(payload)
      response = responder.(decoded) |> Map.put("@extra", decoded["@extra"])
      send(self(), {:td_message, Jason.encode!(response)})
      :ok
    end)

    {:ok, session} =
      Toddy.Session.start_link(
        phone_number: "+1",
        session_dir: Path.join(dir, "session"),
        api_id: 1,
        api_hash: "h",
        native: Mock
      )

    session
  end

  defp completed_file_response(dir, content) do
    path = Path.join(dir, "tdlib_downloaded_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    %{"@type" => "file", "local" => %{"path" => path, "is_downloading_completed" => true}}
  end

  test "a completed download's size on disk is verified against the source size", %{dir: dir} do
    session = start_session(dir, fn _decoded -> completed_file_response(dir, "123456789") end)
    destination = Path.join(dir, "photo.jpg")

    assert {:ok, %Download{status: :completed, bytes_downloaded: 9}} =
             Download.fetch(session, message(), destination)

    assert File.read!(destination) == "123456789"
  end

  test "a size mismatch is reported as a failed download, not a false success", %{dir: dir} do
    session = start_session(dir, fn _decoded -> completed_file_response(dir, "wrong-size") end)
    destination = Path.join(dir, "photo.jpg")

    assert {:ok, %Download{status: :failed, error: :size_mismatch}} =
             Download.fetch(session, message(), destination)
  end

  test "a server-side (5xx) failure is retried and can still succeed", %{dir: dir} do
    test_pid = self()
    attempt = :counters.new(1, [])

    session =
      start_session(dir, fn _decoded ->
        n = :counters.get(attempt, 1)
        :counters.add(attempt, 1, 1)
        send(test_pid, {:attempt, n + 1})

        if n < 2 do
          %{"@type" => "error", "code" => 500, "message" => "Internal Server Error"}
        else
          completed_file_response(dir, "123456789")
        end
      end)

    destination = Path.join(dir, "photo.jpg")
    assert {:ok, %Download{status: :completed}} = Download.fetch(session, message(), destination)

    assert_received {:attempt, 1}
    assert_received {:attempt, 2}
    assert_received {:attempt, 3}
  end

  test "retries are bounded — persistent server-side failures eventually fail cleanly", %{
    dir: dir
  } do
    session =
      start_session(dir, fn _decoded ->
        %{"@type" => "error", "code" => 500, "message" => "Internal Server Error"}
      end)

    destination = Path.join(dir, "photo.jpg")

    log =
      capture_log(fn ->
        assert {:ok, %Download{status: :failed, error: {:tdlib_error, _msg}}} =
                 Download.fetch(session, message(), destination)
      end)

    assert log =~ "toddy.download_failed"
    refute File.exists?(destination)
  end

  test "a permanent (4xx, non-429) failure is not retried at all", %{dir: dir} do
    test_pid = self()

    session =
      start_session(dir, fn _decoded ->
        send(test_pid, :attempted)
        %{"@type" => "error", "code" => 400, "message" => "FILE_REFERENCE_EXPIRED"}
      end)

    destination = Path.join(dir, "photo.jpg")

    assert {:ok, %Download{status: :failed, error: :media_unavailable}} =
             Download.fetch(session, message(), destination)

    assert_received :attempted
    refute_received :attempted
  end
end
