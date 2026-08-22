defmodule Toddy.ProbesTest do
  @moduledoc """
  Constitution Principle VIII (Wide Events): exactly one consolidated
  OpenTelemetry span per unit-of-work, with the full field set carried as
  span attributes — OpenTelemetry is the sole emission mechanism, no
  `Logger` fallback.
  """
  use ExUnit.Case, async: false

  import Toddy.SpanCase

  alias Toddy.Probes

  test "session_authenticated/4 emits exactly one span named after the unit-of-work" do
    [span] =
      capture_spans(fn ->
        span_ctx = Probes.start_event(:session_authenticate)

        Probes.session_authenticated(
          span_ctx,
          "/tmp/session",
          ["authorizationStateWaitCode", "authorizationStateReady"],
          []
        )
      end)

    assert span.name == :session_authenticate
    assert span.status == :unset
    assert span.attributes[:outcome] == :ready
    assert span.attributes[:session_dir] == "/tmp/session"

    assert span.attributes[:auth_states_visited] == [
             "authorizationStateWaitCode",
             "authorizationStateReady"
           ]

    assert span.attributes[:auth_step_failures] == "[]"
  end

  test "session_closed/4 reports outcome: closed, distinct from session_authenticated" do
    [span] =
      capture_spans(fn ->
        span_ctx = Probes.start_event(:session_authenticate)

        Probes.session_closed(
          span_ctx,
          "/tmp/session",
          ["authorizationStateWaitCode"],
          [%{request_type: "setTdlibParameters", code: 400, message: "boom"}]
        )
      end)

    assert span.name == :session_authenticate
    assert span.status == :unset
    assert span.attributes[:outcome] == :closed

    assert span.attributes[:auth_step_failures] ==
             Jason.encode!([%{request_type: "setTdlibParameters", code: 400, message: "boom"}])
  end

  test "group_found/3 and group_not_found/2 tag distinct outcomes on the same span name" do
    group = %Toddy.Group{id: 42, title: "My Group"}

    [found] =
      capture_spans(fn ->
        Probes.group_found(Probes.start_event(:group_find), "My Group", group)
      end)

    [not_found] =
      capture_spans(fn ->
        Probes.group_not_found(Probes.start_event(:group_find), "Missing")
      end)

    assert found.name == :group_find
    assert found.status == :unset
    assert found.attributes[:outcome] == :found
    assert found.attributes[:group_id] == 42

    assert not_found.name == :group_find
    assert not_found.status == :error
    assert not_found.attributes[:outcome] == :not_found
  end

  test "download_batch_completed/3 summarizes a batch as one span, not one per item" do
    downloads = [
      %Toddy.Download{remote_file_id: "a", destination_path: "/tmp/a", status: :completed},
      %Toddy.Download{remote_file_id: "b", destination_path: "/tmp/b", status: :failed}
    ]

    [span] =
      capture_spans(fn ->
        Probes.download_batch_completed(Probes.start_event(:download_batch), downloads, :date)
      end)

    assert span.name == :download_batch
    assert span.status == :error
    assert span.attributes[:outcome] == :partial_failure
    assert span.attributes[:total] == 2
    assert span.attributes[:completed] == 1
    assert span.attributes[:failed] == 1
    assert span.attributes[:group_by] == :date
  end

  test "rate_limited/1 is a standalone instantaneous span" do
    [span] = capture_spans(fn -> Probes.rate_limited(5) end)

    assert span.name == :rate_limited
    assert span.attributes[:retry_after_seconds] == 5
  end
end
