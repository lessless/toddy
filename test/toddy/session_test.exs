defmodule Toddy.SessionTest do
  @moduledoc """
  User Story 1 (Authenticate a Telegram Account): drives the full TDLib
  updateAuthorizationState push sequence through a mocked native layer and
  asserts on Toddy.Session's resulting auth_state, permission enforcement,
  and probe wiring (FR-001, FR-002; SC-001, SC-002).
  """
  use ExUnit.Case, async: false
  import Mox
  import ExUnit.CaptureLog

  alias Toddy.Native.Mock
  alias Toddy.Session

  setup :set_mox_global
  setup :verify_on_exit!

  defp session_dir do
    Path.join(System.tmp_dir!(), "toddy_session_test_#{System.unique_integer([:positive])}")
  end

  defp push(session, decoded), do: send(session, {:td_message, Jason.encode!(decoded)})

  defp auth_update(type),
    do: %{"@type" => "updateAuthorizationState", "authorization_state" => %{"@type" => type}}

  test "drives the login flow to :ready and enforces file permissions" do
    dir = session_dir()
    on_exit(fn -> File.rm_rf!(dir) end)

    test_pid = self()

    Mock
    |> stub(:create, fn -> make_ref() end)
    |> stub(:receive, fn _handle, _timeout ->
      Process.sleep(5)
      nil
    end)
    |> stub(:send, fn _handle, payload ->
      send(test_pid, {:native_send, Jason.decode!(payload)})
      :ok
    end)

    {:ok, session} =
      Session.start_link(
        phone_number: "+15550000000",
        session_dir: dir,
        api_id: 1,
        api_hash: "hash",
        native: Mock
      )

    assert Session.status(session) == :unauthenticated
    assert File.stat!(dir).mode |> rem(0o1000) == 0o700

    push(session, auth_update("authorizationStateWaitTdlibParameters"))

    assert_receive {:native_send, %{"@type" => "setTdlibParameters", "api_id" => 1}}, 1000

    push(session, auth_update("authorizationStateWaitPhoneNumber"))

    assert_receive {:native_send,
                    %{"@type" => "setAuthenticationPhoneNumber", "phone_number" => "+15550000000"}},
                   1000

    push(session, auth_update("authorizationStateWaitCode"))
    assert Session.status(session) == :wait_code

    File.write!(Path.join(dir, "fake_session.db"), "data")

    task = Task.async(fn -> Session.submit_code(session, "12345") end)

    assert_receive {:native_send,
                    %{"@type" => "checkAuthenticationCode", "code" => "12345"} = req},
                   1000

    push(session, %{"@type" => "ok", "@extra" => req["@extra"]})
    assert Task.await(task) == :ok

    push(session, auth_update("authorizationStateWaitPassword"))
    assert Session.status(session) == :wait_password

    task2 = Task.async(fn -> Session.submit_password(session, "secret") end)

    assert_receive {:native_send,
                    %{"@type" => "checkAuthenticationPassword", "password" => "secret"} = req2},
                   1000

    push(session, %{"@type" => "ok", "@extra" => req2["@extra"]})
    assert Task.await(task2) == :ok

    log =
      capture_log(fn ->
        push(session, auth_update("authorizationStateReady"))
        Process.sleep(20)
      end)

    assert Session.status(session) == :ready
    assert log =~ "toddy.wide_event event=session_authenticate"
    assert log =~ "outcome=ready"
    assert log =~ "authorizationStateWaitCode"
    assert log =~ "authorizationStateWaitPassword"
    assert File.stat!(Path.join(dir, "fake_session.db")).mode |> rem(0o1000) == 0o600
  end

  test "submit_code is rejected outside :wait_code" do
    dir = session_dir()
    on_exit(fn -> File.rm_rf!(dir) end)

    Mock
    |> stub(:create, fn -> make_ref() end)
    |> stub(:send, fn _handle, _payload -> :ok end)
    |> stub(:receive, fn _handle, _timeout ->
      Process.sleep(5)
      nil
    end)

    {:ok, session} =
      Session.start_link(
        phone_number: "+15550000000",
        session_dir: dir,
        api_id: 1,
        api_hash: "hash",
        native: Mock
      )

    assert Session.submit_code(session, "12345") == {:error, :unexpected_state}
  end

  test "a reconnect against a session directory that is already :ready-equivalent needs no re-auth prompts" do
    # Simulated by directly pushing authorizationStateReady without any
    # wait_code/wait_password step — mirrors TDLib reconnecting from a
    # persisted session directory (SC-002).
    dir = session_dir()
    on_exit(fn -> File.rm_rf!(dir) end)

    Mock
    |> stub(:create, fn -> make_ref() end)
    |> stub(:send, fn _handle, _payload -> :ok end)
    |> stub(:receive, fn _handle, _timeout ->
      Process.sleep(5)
      nil
    end)

    {:ok, session} =
      Session.start_link(
        phone_number: "+15550000000",
        session_dir: dir,
        api_id: 1,
        api_hash: "hash",
        native: Mock
      )

    push(session, auth_update("authorizationStateReady"))
    Process.sleep(20)

    assert Session.status(session) == :ready
  end

  test "a fire-and-forget failure during the handshake is folded into the final wide event" do
    dir = session_dir()
    on_exit(fn -> File.rm_rf!(dir) end)

    Mock
    |> stub(:create, fn -> make_ref() end)
    |> stub(:send, fn _handle, payload ->
      decoded = Jason.decode!(payload)

      if decoded["@type"] == "setTdlibParameters" do
        send(
          self(),
          {:td_message,
           Jason.encode!(%{
             "@type" => "error",
             "code" => 400,
             "message" => "boom",
             "@extra" => decoded["@extra"]
           })}
        )
      end

      :ok
    end)
    |> stub(:receive, fn _handle, _timeout ->
      Process.sleep(5)
      nil
    end)

    {:ok, session} =
      Session.start_link(
        phone_number: "+15550000000",
        session_dir: dir,
        api_id: 1,
        api_hash: "hash",
        native: Mock
      )

    push(session, auth_update("authorizationStateWaitTdlibParameters"))
    Process.sleep(20)

    log =
      capture_log(fn ->
        push(session, auth_update("authorizationStateReady"))
        Process.sleep(20)
      end)

    assert log =~ "toddy.wide_event event=session_authenticate"
    assert log =~ "outcome=ready"
    assert log =~ ~s(request_type: "setTdlibParameters")
    assert log =~ "code: 400"
    assert log =~ ~s(message: "boom")
  end

  test "reaching :closed without ever becoming :ready is its own wide-event outcome" do
    dir = session_dir()
    on_exit(fn -> File.rm_rf!(dir) end)

    Mock
    |> stub(:create, fn -> make_ref() end)
    |> stub(:send, fn _handle, _payload -> :ok end)
    |> stub(:receive, fn _handle, _timeout ->
      Process.sleep(5)
      nil
    end)

    {:ok, session} =
      Session.start_link(
        phone_number: "+15550000000",
        session_dir: dir,
        api_id: 1,
        api_hash: "hash",
        native: Mock
      )

    log =
      capture_log(fn ->
        push(session, auth_update("authorizationStateWaitCode"))
        push(session, auth_update("authorizationStateClosed"))
        Process.sleep(20)
      end)

    assert Session.status(session) == :closed
    assert log =~ "toddy.wide_event event=session_authenticate"
    assert log =~ "outcome=closed"
  end
end
