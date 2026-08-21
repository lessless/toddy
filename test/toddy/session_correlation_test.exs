defmodule Toddy.SessionCorrelationTest do
  @moduledoc """
  Exercises @extra-based request/response correlation and unsolicited-update
  dispatch (research.md R5) against a mocked native layer.

  Uses Mox global mode (not async) because Toddy.Session's native calls
  happen from its own GenServer process and a dedicated receive-loop
  process, not the test process itself.
  """
  use ExUnit.Case, async: false
  import Mox

  alias Toddy.Native.Mock
  alias Toddy.Session

  setup :set_mox_global
  setup :verify_on_exit!
  setup :start_ready_session

  defp start_ready_session(_context) do
    Mock
    |> stub(:create, fn -> make_ref() end)
    |> stub(:send, fn _handle, _payload -> :ok end)
    |> stub(:receive, fn _handle, _timeout ->
      Process.sleep(5)
      nil
    end)

    dir = session_dir()

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

  defp session_dir do
    Path.join(System.tmp_dir!(), "toddy_correlation_test_#{System.unique_integer([:positive])}")
  end

  test "a response with a matching @extra resolves the waiting caller", %{session: session} do
    test_pid = self()

    Mock
    |> expect(:send, fn _handle, payload ->
      decoded = Jason.decode!(payload)
      assert decoded["@type"] == "getChats"
      send(test_pid, {:sent, decoded["@extra"]})
      :ok
    end)

    task =
      Task.async(fn ->
        Session.request(session, %{"@type" => "getChats"})
      end)

    assert_receive {:sent, extra}, 1000
    response = %{"@type" => "chats", "chat_ids" => [1, 2, 3], "@extra" => extra}
    send(session, {:td_message, Jason.encode!(response)})

    assert Task.await(task) == response
  end

  test "an unsolicited update (no @extra) is delivered to subscribers", %{session: session} do
    :ok = Session.subscribe(session)

    update = %{"@type" => "updateNewMessage", "message" => %{"id" => 42}}
    send(session, {:td_message, Jason.encode!(update)})

    assert_receive {:toddy_update, ^update}, 1000
  end

  test "a response for an unknown @extra does not crash the session", %{session: session} do
    send(session, {:td_message, Jason.encode!(%{"@type" => "ok", "@extra" => "stale-id"})})
    assert Session.status(session) in [:unauthenticated, :wait_code, :wait_password, :ready]
  end
end
