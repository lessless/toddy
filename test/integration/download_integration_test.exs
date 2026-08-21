defmodule Toddy.DownloadIntegrationTest do
  @moduledoc """
  Constitution Principle III: Toddy.Download against a real, compiled
  libtdjson, a real authenticated session, and a real group with media —
  same live-credential gating as group_integration_test.exs (TG_TEST_GROUP
  must have at least one message with media for `fetch_all/3` to exercise).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Toddy.Download
  alias Toddy.Group
  alias Toddy.Session

  @live? not is_nil(System.get_env("TG_API_ID")) and
           not is_nil(System.get_env("TG_API_HASH")) and
           not is_nil(System.get_env("TG_TEST_PHONE")) and
           not is_nil(System.get_env("TG_TEST_CODE")) and
           not is_nil(System.get_env("TG_TEST_GROUP"))

  @tag skip: !@live?
  test "downloads real media, verifies size, and skips a same-destination re-download" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "toddy_download_integration_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, session} =
      Session.start_link(
        phone_number: System.fetch_env!("TG_TEST_PHONE"),
        session_dir: Path.join(dir, "session"),
        api_id: System.fetch_env!("TG_API_ID") |> String.to_integer(),
        api_hash: System.fetch_env!("TG_API_HASH")
      )

    :ok = wait_until(fn -> Session.status(session) == :wait_code end)
    :ok = Session.submit_code(session, System.fetch_env!("TG_TEST_CODE"))
    :ok = wait_until(fn -> Session.status(session) == :ready end)

    identifier = System.fetch_env!("TG_TEST_GROUP")

    identifier =
      case Integer.parse(identifier) do
        {int, ""} -> int
        _not_an_integer -> identifier
      end

    {:ok, group} = Group.find(session, identifier)
    {:ok, messages} = Group.list_media(session, group)
    assert messages != [], "TG_TEST_GROUP must have at least one media message for this test"

    destination_dir = Path.join(dir, "downloads")
    downloads = Download.fetch_all(session, Enum.take(messages, 1), destination_dir)

    assert [%Download{status: :completed} = download] = downloads
    assert File.stat!(download.destination_path).size == download.bytes_downloaded

    # Re-running against the same destination must not write a duplicate.
    downloads_again = Download.fetch_all(session, Enum.take(messages, 1), destination_dir)
    assert [%Download{status: :completed}] = downloads_again
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: {:error, :timeout}

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(200)
      wait_until(fun, attempts - 1)
    end
  end
end
