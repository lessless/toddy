defmodule Toddy.Session do
  @moduledoc """
  Owns one authenticated TDLib connection.

  Drives TDLib's `updateAuthorizationState` push-driven login flow
  automatically up through phone-number submission, and exposes `status/1`,
  `submit_code/2`, and `submit_password/2` for the steps that need caller
  input. Also provides the generic `request/3` + `subscribe/1` primitives
  that `Toddy.Group` and `Toddy.Download` build on (research.md R5).
  """

  use GenServer

  alias Toddy.Probes

  @default_native Toddy.Native.TdJson
  @receive_timeout_seconds 10.0

  # Client API

  @doc """
  Starts a session and begins authenticating: creates the TDLib client,
  restricts `session_dir` to `0700` (FR-002), and immediately drives the
  login handshake up through phone-number submission without any caller
  input. Reconnecting against a `session_dir` that already holds a valid
  TDLib session goes straight to `:ready` (SC-002).

  Required opts: `:phone_number`, `:session_dir`, `:api_id`, `:api_hash`
  (research.md R10). Accepts standard `GenServer.start_link/3` options too.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Returns the current authentication state."
  def status(session), do: GenServer.call(session, :status)

  @doc """
  Submits the verification code while `status/1` reports `:wait_code`.
  Returns `{:error, :unexpected_state}` if called at any other time, or
  `{:error, :invalid_code}` if TDLib rejects the code itself.
  """
  def submit_code(session, code), do: GenServer.call(session, {:submit_code, code})

  @doc """
  Submits the two-factor password while `status/1` reports `:wait_password`.
  Returns `{:error, :unexpected_state}` if called at any other time, or
  `{:error, :invalid_password}` if TDLib rejects the password itself.
  """
  def submit_password(session, password),
    do: GenServer.call(session, {:submit_password, password})

  @doc """
  Sends a raw TDLib request and returns its correlated, JSON-decoded
  response. Used internally by `Toddy.Group` and `Toddy.Download`; not part
  of the consumer-facing contract in contracts/toddy_api.md.
  """
  def request(session, request_map, timeout \\ 30_000) do
    GenServer.call(session, {:request, request_map}, timeout)
  end

  @doc """
  Registers the calling process to receive `{:toddy_update, decoded_map}`
  messages for every unsolicited TDLib update that isn't a response to a
  tracked request or an authorization-state change (both handled
  internally). Foundational infrastructure (research.md R5) — no current
  user story needs it directly, since `Toddy.Download` uses synchronous
  `downloadFile` rather than polling `updateFile` pushes — but it's the
  extension point for anything that does.
  """
  def subscribe(session), do: GenServer.call(session, {:subscribe, self()})

  # Server callbacks

  @impl true
  def init(opts) do
    phone_number = Keyword.fetch!(opts, :phone_number)
    session_dir = Keyword.fetch!(opts, :session_dir)
    api_id = Keyword.fetch!(opts, :api_id)
    api_hash = Keyword.fetch!(opts, :api_hash)
    native = Keyword.get(opts, :native, @default_native)
    use_test_dc = Keyword.get(opts, :use_test_dc, false)

    File.mkdir_p!(session_dir)
    File.chmod!(session_dir, 0o700)

    handle = native.create()

    state = %{
      phone_number: phone_number,
      use_test_dc: use_test_dc,
      session_dir: session_dir,
      api_id: api_id,
      api_hash: api_hash,
      native: native,
      handle: handle,
      auth_state: :unauthenticated,
      pending_requests: %{},
      pending_bodies: %{},
      fire_and_forget_extras: %{},
      subscribers: [],
      wide_event_span_ctx: Probes.start_event(:session_authenticate),
      auth_states_visited: [],
      auth_step_failures: []
    }

    {:ok, state, {:continue, :start_receiver}}
  end

  @impl true
  def handle_continue(:start_receiver, state) do
    parent = self()
    native = state.native
    handle = state.handle

    {:ok, _receiver} =
      Task.start_link(fn -> receive_loop(parent, native, handle) end)

    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.auth_state, state}
  end

  def handle_call({:submit_code, _code}, _from, %{auth_state: auth_state} = state)
      when auth_state != :wait_code do
    {:reply, {:error, :unexpected_state}, state}
  end

  def handle_call({:submit_code, code}, from, state) do
    send_correlated(
      %{"@type" => "checkAuthenticationCode", "code" => code},
      from,
      state,
      &auth_check_result(&1, :invalid_code)
    )
  end

  def handle_call({:submit_password, _password}, _from, %{auth_state: auth_state} = state)
      when auth_state != :wait_password do
    {:reply, {:error, :unexpected_state}, state}
  end

  def handle_call({:submit_password, password}, from, state) do
    send_correlated(
      %{"@type" => "checkAuthenticationPassword", "password" => password},
      from,
      state,
      &auth_check_result(&1, :invalid_password)
    )
  end

  def handle_call({:request, request_map}, from, state) do
    send_correlated(request_map, from, state, & &1)
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_info({:td_message, payload}, state) do
    case Jason.decode(payload) do
      {:ok, decoded} -> process_message(decoded, state)
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_info({:retry_request, from, transform, original_body}, state) do
    {:noreply, dispatch_request(original_body, from, transform, state)}
  end

  @impl true
  def terminate(_reason, state) do
    if state.handle do
      state.native.send(state.handle, Jason.encode!(%{"@type" => "close"}))
    end

    :ok
  end

  defp receive_loop(parent, native, handle) do
    case native.receive(handle, @receive_timeout_seconds) do
      nil -> :ok
      payload -> send(parent, {:td_message, payload})
    end

    receive_loop(parent, native, handle)
  end

  defp send_correlated(request_map, from, state, transform) do
    {:noreply, dispatch_request(request_map, from, transform, state)}
  end

  defp dispatch_request(request_map, from, transform, state) do
    extra = generate_extra()
    :ok = state.native.send(state.handle, Jason.encode!(Map.put(request_map, "@extra", extra)))

    %{
      state
      | pending_requests: Map.put(state.pending_requests, extra, {from, transform}),
        pending_bodies: Map.put(state.pending_bodies, extra, request_map)
    }
  end

  defp fire_and_forget(request_map, state) do
    extra = generate_extra()
    state.native.send(state.handle, Jason.encode!(Map.put(request_map, "@extra", extra)))

    %{
      state
      | fire_and_forget_extras: Map.put(state.fire_and_forget_extras, extra, request_map["@type"])
    }
  end

  defp generate_extra do
    :erlang.unique_integer([:positive, :monotonic]) |> Integer.to_string()
  end

  defp process_message(%{"@extra" => extra} = decoded, state) do
    cond do
      Map.has_key?(state.pending_requests, extra) ->
        handle_correlated_response(extra, decoded, state)

      Map.has_key?(state.fire_and_forget_extras, extra) ->
        handle_fire_and_forget_response(extra, decoded, state)

      true ->
        dispatch_unsolicited(decoded, state)
    end
  end

  defp process_message(decoded, state), do: dispatch_unsolicited(decoded, state)

  # Fire-and-forget requests (the auto-driven login steps) aren't correlated
  # back to a caller, but an error response still deserves to be surfaced
  # rather than silently dropped.
  defp handle_fire_and_forget_response(
         extra,
         %{"@type" => "error", "code" => code, "message" => message},
         state
       ) do
    request_type = state.fire_and_forget_extras[extra]
    failure = %{request_type: request_type, code: code, message: message}

    state = %{
      state
      | fire_and_forget_extras: Map.delete(state.fire_and_forget_extras, extra),
        auth_step_failures: [failure | state.auth_step_failures]
    }

    {:noreply, state}
  end

  defp handle_fire_and_forget_response(extra, _decoded, state) do
    {:noreply, %{state | fire_and_forget_extras: Map.delete(state.fire_and_forget_extras, extra)}}
  end

  # Flood-wait (FR-013, research.md R9): wait out the server-specified delay
  # and transparently resend, rather than replying with the 429 to the caller.
  defp handle_correlated_response(
         extra,
         %{"@type" => "error", "code" => 429, "message" => message},
         state
       ) do
    {from, transform} = state.pending_requests[extra]
    original_body = state.pending_bodies[extra]
    retry_after = parse_retry_after(message)
    Probes.rate_limited(retry_after)

    Process.send_after(
      self(),
      {:retry_request, from, transform, original_body},
      trunc(retry_after * 1000)
    )

    {:noreply, clear_pending(state, extra)}
  end

  defp handle_correlated_response(extra, decoded, state) do
    {from, transform} = state.pending_requests[extra]
    GenServer.reply(from, transform.(decoded))
    {:noreply, clear_pending(state, extra)}
  end

  defp clear_pending(state, extra) do
    %{
      state
      | pending_requests: Map.delete(state.pending_requests, extra),
        pending_bodies: Map.delete(state.pending_bodies, extra)
    }
  end

  defp parse_retry_after(message) do
    case Regex.run(~r/retry after (\d+)/, message) do
      [_match, seconds] -> String.to_integer(seconds)
      _ -> 1
    end
  end

  defp auth_check_result(%{"@type" => "ok"}, _error_reason), do: :ok
  defp auth_check_result(%{"@type" => "error"}, error_reason), do: {:error, error_reason}

  defp dispatch_unsolicited(
         %{
           "@type" => "updateAuthorizationState",
           "authorization_state" => %{"@type" => type} = auth
         },
         state
       ) do
    state = %{state | auth_states_visited: [type | state.auth_states_visited]}
    handle_auth_update(auth, state)
  end

  defp dispatch_unsolicited(decoded, state) do
    Enum.each(state.subscribers, &send(&1, {:toddy_update, decoded}))
    {:noreply, state}
  end

  defp handle_auth_update(%{"@type" => "authorizationStateWaitTdlibParameters"}, state) do
    new_state =
      fire_and_forget(
        %{
          "@type" => "setTdlibParameters",
          "use_test_dc" => state.use_test_dc,
          "database_directory" => state.session_dir,
          "use_message_database" => false,
          "use_secret_chats" => false,
          "api_id" => state.api_id,
          "api_hash" => state.api_hash,
          "system_language_code" => "en",
          "device_model" => "Toddy",
          "application_version" => "0.1.0"
        },
        state
      )

    {:noreply, new_state}
  end

  defp handle_auth_update(%{"@type" => "authorizationStateWaitEncryptionKey"}, state) do
    new_state =
      fire_and_forget(%{"@type" => "checkDatabaseEncryptionKey", "encryption_key" => ""}, state)

    {:noreply, new_state}
  end

  defp handle_auth_update(%{"@type" => "authorizationStateWaitPhoneNumber"}, state) do
    new_state =
      fire_and_forget(
        %{"@type" => "setAuthenticationPhoneNumber", "phone_number" => state.phone_number},
        state
      )

    {:noreply, new_state}
  end

  defp handle_auth_update(%{"@type" => "authorizationStateWaitCode"}, state) do
    {:noreply, %{state | auth_state: :wait_code}}
  end

  defp handle_auth_update(%{"@type" => "authorizationStateWaitPassword"}, state) do
    {:noreply, %{state | auth_state: :wait_password}}
  end

  defp handle_auth_update(%{"@type" => "authorizationStateReady"}, state) do
    enforce_session_permissions(state.session_dir)

    Probes.session_authenticated(
      state.wide_event_span_ctx,
      state.session_dir,
      Enum.reverse(state.auth_states_visited),
      Enum.reverse(state.auth_step_failures)
    )

    {:noreply, %{state | auth_state: :ready}}
  end

  defp handle_auth_update(%{"@type" => "authorizationStateClosed"}, state) do
    Probes.session_closed(
      state.wide_event_span_ctx,
      state.session_dir,
      Enum.reverse(state.auth_states_visited),
      Enum.reverse(state.auth_step_failures)
    )

    {:noreply, %{state | auth_state: :closed}}
  end

  defp handle_auth_update(_other, state), do: {:noreply, state}

  defp enforce_session_permissions(session_dir) do
    session_dir
    |> File.ls!()
    |> Enum.each(fn entry ->
      path = Path.join(session_dir, entry)
      if File.regular?(path), do: File.chmod!(path, 0o600)
    end)
  end
end
