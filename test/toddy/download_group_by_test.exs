defmodule Toddy.DownloadGroupByTest do
  @moduledoc """
  Opt-in `group_by: :date` on `fetch_all/3` — organizes downloads into
  dd-mm-yyyy subfolders named after the message's post date, without
  changing the default flat-`destination_dir` behavior (already documented,
  tested, and live-verified).
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
    dir =
      Path.join(System.tmp_dir!(), "toddy_group_by_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp message(id, date, remote_file_id, file_name) do
    %Message{
      id: id,
      chat_id: 1,
      date: date,
      media: %MediaItem{
        remote_file_id: remote_file_id,
        file_id: id,
        type: :photo,
        size: 9,
        file_name: file_name
      }
    }
  end

  defp start_session(dir) do
    Mock
    |> stub(:create, fn -> make_ref() end)
    |> stub(:receive, fn _h, _t ->
      Process.sleep(5)
      nil
    end)
    |> stub(:send, fn _handle, payload ->
      decoded = Jason.decode!(payload)
      path = Path.join(dir, "src_#{System.unique_integer([:positive])}")
      File.write!(path, "123456789")

      response = %{
        "@type" => "file",
        "local" => %{"path" => path, "is_downloading_completed" => true},
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

    session
  end

  test "group_by: :date writes into a dd-mm-yyyy subfolder named after the message's post date",
       %{dir: dir} do
    session = start_session(dir)
    posted_at = DateTime.new!(~D[2026-08-21], ~T[10:00:00], "Etc/UTC")
    msg = message(1, posted_at, "unique-1", "photo.jpg")

    [download] = Download.fetch_all(session, [msg], dir, group_by: :date)

    assert download.status == :completed
    assert download.destination_path == Path.join([dir, "21-08-2026", "photo.jpg"])
    assert File.exists?(download.destination_path)
  end

  test "different messages land in different date folders", %{dir: dir} do
    session = start_session(dir)

    msg1 = message(1, DateTime.new!(~D[2026-08-21], ~T[10:00:00], "Etc/UTC"), "unique-1", "a.jpg")
    msg2 = message(2, DateTime.new!(~D[2026-01-05], ~T[10:00:00], "Etc/UTC"), "unique-2", "b.jpg")

    [d1, d2] = Download.fetch_all(session, [msg1, msg2], dir, group_by: :date)

    assert d1.destination_path == Path.join([dir, "21-08-2026", "a.jpg"])
    assert d2.destination_path == Path.join([dir, "05-01-2026", "b.jpg"])
  end

  test "without group_by, fetch_all/3 keeps writing flat into destination_dir (unchanged default)",
       %{dir: dir} do
    session = start_session(dir)
    posted_at = DateTime.new!(~D[2026-08-21], ~T[10:00:00], "Etc/UTC")
    msg = message(1, posted_at, "unique-1", "photo.jpg")

    [download] = Download.fetch_all(session, [msg], dir)

    assert download.destination_path == Path.join(dir, "photo.jpg")
  end

  test "a media item with an empty (not nil) file_name — as TDLib sends for in-app-recorded videos — falls back to remote_file_id, instead of colliding with its own date folder",
       %{dir: dir} do
    session = start_session(dir)
    posted_at = DateTime.new!(~D[2026-08-01], ~T[10:00:00], "Etc/UTC")

    msg1 = message(1, posted_at, "unique-1", "")
    msg2 = message(2, posted_at, "unique-2", "clip.mp4")

    [d1, d2] = Download.fetch_all(session, [msg1, msg2], dir, group_by: :date)

    assert d1.status == :completed
    assert d1.destination_path == Path.join([dir, "01-08-2026", "unique-1"])

    assert d2.status == :completed
    assert d2.destination_path == Path.join([dir, "01-08-2026", "clip.mp4"])
  end
end
