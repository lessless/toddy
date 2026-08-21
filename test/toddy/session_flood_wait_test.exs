defmodule Toddy.SessionFloodWaitTest do
  @moduledoc """
  FR-013 / research.md R9: a TDLib flood-wait (code 429) error is waited out
  and the original request transparently retried, rather than surfaced to
  the caller as a failure.
  """
  use ExUnit.Case, async: false
  import Mox

  alias Toddy.Native.Mock
  alias Toddy.Session

  setup :set_mox_global
  setup :verify_on_exit!

  defp start_session(_context) do
    Mock
    |> stub(:create, fn -> make_ref() end)
    |> stub(:receive, fn _handle, _timeout ->
      Process.sleep(5)
      nil
    end)

    dir =
      Path.join(System.tmp_dir!(), "toddy_flood_wait_test_#{System.unique_integer([:positive])}")

    {:ok, session} =
      Session.start_link(
        phone_number: "+15550000000",
        session_dir: dir,
        api_id: 1,
        api_hash: "hash",
        native: Mock
      )

    on_exit(fn -> File.rm_rf!(dir) end)

    %{session: session}
  end

  setup :start_session

  test "a 429 response is waited out and the request is transparently retried", %{
    session: session
  } do
    test_pid = self()

    Mock
    |> expect(:send, fn _handle, payload ->
      decoded = Jason.decode!(payload)
      send(test_pid, {:sent, 1, decoded["@extra"]})
      :ok
    end)
    |> expect(:send, fn _handle, payload ->
      decoded = Jason.decode!(payload)
      send(test_pid, {:sent, 2, decoded["@extra"]})
      :ok
    end)

    task = Task.async(fn -> Session.request(session, %{"@type" => "getChats"}) end)

    assert_receive {:sent, 1, first_extra}, 1000

    flood_wait_error = %{
      "@type" => "error",
      "code" => 429,
      "message" => "Too Many Requests: retry after 0",
      "@extra" => first_extra
    }

    send(session, {:td_message, Jason.encode!(flood_wait_error)})

    assert_receive {:sent, 2, second_extra}, 1000
    refute second_extra == first_extra

    success = %{"@type" => "chats", "chat_ids" => [1], "@extra" => second_extra}
    send(session, {:td_message, Jason.encode!(success)})

    assert Task.await(task) == success
  end
end
