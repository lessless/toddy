defmodule Toddy.DownloadDedupTest do
  @moduledoc """
  User Story 3: skip-if-already-downloaded, keyed on (remote_file_id,
  destination_path) — the destination file's own presence/size on disk is
  the dedup record (FR-007, SC-006).
  """
  use ExUnit.Case, async: false
  import Mox

  alias Toddy.Download
  alias Toddy.MediaItem
  alias Toddy.Message
  alias Toddy.Native.Mock

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    dir = Path.join(System.tmp_dir!(), "toddy_dedup_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp media(overrides \\ %{}) do
    struct(
      %MediaItem{remote_file_id: "unique-1", file_id: 1, type: :photo, size: 9},
      overrides
    )
  end

  defp message(media), do: %Message{id: 1, chat_id: 1, date: DateTime.utc_now(), media: media}

  test "a file already on disk with the expected size is not re-downloaded", %{dir: dir} do
    destination = Path.join(dir, "photo.jpg")
    File.write!(destination, "123456789")

    Mock
    |> expect(:create, 0, fn -> flunk("should not touch the native layer at all") end)

    assert {:ok, %Download{status: :completed, bytes_downloaded: 9}} =
             Download.fetch(nil, message(media()), destination)
  end

  test "a re-run against the same destination produces zero duplicate downloads", %{dir: dir} do
    destination = Path.join(dir, "photo.jpg")
    File.write!(destination, "123456789")
    mtime_before = File.stat!(destination).mtime

    Mock
    |> expect(:send, 0, fn _handle, _payload -> flunk("should not have re-downloaded") end)

    {:ok, first} = Download.fetch(nil, message(media()), destination)
    {:ok, second} = Download.fetch(nil, message(media()), destination)

    assert first.status == :completed
    assert second.status == :completed
    assert File.stat!(destination).mtime == mtime_before
  end

  test "a file on disk with the WRONG size is treated as not yet downloaded", %{dir: dir} do
    destination = Path.join(dir, "photo.jpg")
    File.write!(destination, "wrong size")

    Mock
    |> stub(:create, fn -> make_ref() end)
    |> stub(:receive, fn _h, _t ->
      Process.sleep(5)
      nil
    end)
    |> expect(:send, fn _handle, payload ->
      decoded = Jason.decode!(payload)
      assert decoded["@type"] == "downloadFile"

      response = %{
        "@type" => "file",
        "local" => %{
          "path" => make_source_file(dir, "123456789"),
          "is_downloading_completed" => true
        },
        "@extra" => decoded["@extra"]
      }

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

    assert {:ok, %Download{status: :completed}} =
             Download.fetch(session, message(media()), destination)
  end

  defp make_source_file(dir, content) do
    path = Path.join(dir, "tdlib_downloaded_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    path
  end
end
