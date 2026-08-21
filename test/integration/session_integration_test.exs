defmodule Toddy.SessionIntegrationTest do
  @moduledoc """
  Constitution Principle III: verifies Toddy.Session against a real, compiled
  libtdjson — not the mocked native layer.

  The first test runs unconditionally: it only needs a working libtdjson, and
  confirmed (via manual exploration during implementation) that Toddy.Session
  correctly drives TDLib's real handshake — authorizationStateWaitTdlibParameters
  (nested `parameters`, not flat fields — a real TDLib 1.8.0 API detail this
  test caught) -> authorizationStateWaitEncryptionKey -> authorizationStateWaitPhoneNumber
  -- against live network calls to Telegram, without crashing.

  Reaching :wait_code and beyond additionally requires a real Telegram
  application id/hash (from https://my.telegram.org — the widely-shared demo
  id/hash used elsewhere in this repo's manual checks gets rejected by
  Telegram's servers with UPDATE_APP_TO_LOGIN) and a real phone number able to
  receive a verification code. That test only runs when TG_API_ID, TG_API_HASH,
  and TG_TEST_PHONE are set; submitting the code and verifying reconnect-without
  -re-auth (SC-002) additionally requires TG_TEST_CODE.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Toddy.Session

  @live_creds? not is_nil(System.get_env("TG_API_ID")) and
                 not is_nil(System.get_env("TG_API_HASH")) and
                 not is_nil(System.get_env("TG_TEST_PHONE"))

  @live_code? @live_creds? and not is_nil(System.get_env("TG_TEST_CODE"))

  defp session_dir do
    Path.join(
      System.tmp_dir!(),
      "toddy_session_integration_#{System.unique_integer([:positive])}"
    )
  end

  test "drives the real TDLib handshake without crashing" do
    dir = session_dir()
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, session} =
      Session.start_link(
        phone_number: "+10000000000",
        session_dir: dir,
        api_id: 94_575,
        api_hash: "a3406de8d171bb422bb6ddf3bbd800e2",
        use_test_dc: false
      )

    assert Session.status(session) == :unauthenticated

    # Give the real handshake (setTdlibParameters -> checkDatabaseEncryptionKey
    # -> setAuthenticationPhoneNumber, each round-tripped to Telegram's real
    # servers) time to complete; a bogus phone number means TDLib never moves
    # past :unauthenticated, but the process must stay alive and unharmed.
    Process.sleep(3000)

    assert Process.alive?(session)
    assert File.stat!(dir).mode |> rem(0o1000) == 0o700
  end

  @tag skip: !@live_creds?
  test "reaches :wait_code with real application credentials" do
    dir = session_dir()
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, session} =
      Session.start_link(
        phone_number: System.fetch_env!("TG_TEST_PHONE"),
        session_dir: dir,
        api_id: System.fetch_env!("TG_API_ID") |> String.to_integer(),
        api_hash: System.fetch_env!("TG_API_HASH")
      )

    assert :ok = wait_until(fn -> Session.status(session) == :wait_code end)
  end

  @tag skip: !@live_code?
  test "full authentication + reconnect without re-prompting (SC-001, SC-002)" do
    dir = session_dir()
    on_exit(fn -> File.rm_rf!(dir) end)

    opts = [
      phone_number: System.fetch_env!("TG_TEST_PHONE"),
      session_dir: dir,
      api_id: System.fetch_env!("TG_API_ID") |> String.to_integer(),
      api_hash: System.fetch_env!("TG_API_HASH")
    ]

    {:ok, session} = Session.start_link(opts)

    :ok = wait_until(fn -> Session.status(session) == :wait_code end)
    :ok = Session.submit_code(session, System.fetch_env!("TG_TEST_CODE"))
    :ok = wait_until(fn -> Session.status(session) == :ready end)

    {:ok, reconnected} = Session.start_link(opts)
    :ok = wait_until(fn -> Session.status(reconnected) == :ready end)
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
