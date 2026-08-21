defmodule Toddy.GroupIntegrationTest do
  @moduledoc """
  Constitution Principle III: Toddy.Group against a real, compiled libtdjson
  and a real authenticated session. Requires a full live login (see
  session_integration_test.exs) plus TG_TEST_GROUP (the exact title or id of
  a group the test account already belongs to) — skipped otherwise.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Toddy.Group
  alias Toddy.Session

  @live? not is_nil(System.get_env("TG_API_ID")) and
           not is_nil(System.get_env("TG_API_HASH")) and
           not is_nil(System.get_env("TG_TEST_PHONE")) and
           not is_nil(System.get_env("TG_TEST_CODE")) and
           not is_nil(System.get_env("TG_TEST_GROUP"))

  @tag skip: !@live?
  test "finds a real group and lists its media" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "toddy_group_integration_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, session} =
      Session.start_link(
        phone_number: System.fetch_env!("TG_TEST_PHONE"),
        session_dir: dir,
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

    assert {:ok, group} = Group.find(session, identifier)
    assert {:ok, messages} = Group.list_media(session, group)
    assert Enum.all?(messages, &(&1.media != nil))

    assert Group.find(session, "definitely-not-a-real-group-#{System.unique_integer()}") ==
             {:error, :group_not_found}
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
