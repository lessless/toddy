defmodule Toddy.ProbesTest do
  @moduledoc """
  Constitution Principle VIII (Wide Events): exactly one consolidated,
  structured log line per unit-of-work, formatted so the full field set is
  visible in the message itself — not dependent on a consuming application
  having configured Logger to print custom metadata.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Toddy.Probes

  test "start_event/0 returns a monotonically non-decreasing token usable for timing" do
    a = Probes.start_event()
    b = Probes.start_event()
    assert is_integer(a)
    assert is_integer(b)
    assert b >= a
  end

  test "session_authenticated/4 emits exactly one wide event with the fixed event tag" do
    log =
      capture_log(fn ->
        started_at = Probes.start_event() - 5
        Probes.session_authenticated(started_at, "/tmp/session", [:wait_code, :ready], [])
      end)

    lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "toddy.wide_event"))
    assert length(lines) == 1

    line = hd(lines)
    assert line =~ "event=session_authenticate"
    assert line =~ "outcome=ready"
    assert line =~ "session_dir=\"/tmp/session\""
    assert line =~ ~r/duration_ms=\d+/
    assert line =~ "auth_states_visited=[:wait_code, :ready]"
  end

  test "session_closed/4 reports outcome: closed, distinct from session_authenticated" do
    log =
      capture_log(fn ->
        started_at = Probes.start_event()
        Probes.session_closed(started_at, "/tmp/session", [:wait_code], [%{code: 400}])
      end)

    assert log =~ "event=session_authenticate"
    assert log =~ "outcome=closed"
    assert log =~ "auth_step_failures=[%{code: 400}]"
  end

  test "group_found/3 and group_not_found/2 tag distinct outcomes on the same event name" do
    group = %Toddy.Group{id: 42, title: "My Group"}

    found_log =
      capture_log(fn -> Probes.group_found(Probes.start_event(), "My Group", group) end)

    not_found_log =
      capture_log(fn -> Probes.group_not_found(Probes.start_event(), "Missing") end)

    assert found_log =~ "event=group_find"
    assert found_log =~ "outcome=found"
    assert found_log =~ "group_id=42"

    assert not_found_log =~ "event=group_find"
    assert not_found_log =~ "outcome=not_found"
  end

  test "failure outcomes log at :warning; success outcomes log at :info" do
    warning_log =
      capture_log([level: :warning], fn ->
        Probes.group_not_found(Probes.start_event(), "Missing")
      end)

    assert warning_log =~ "outcome=not_found"

    info_only_log =
      capture_log([level: :warning], fn ->
        Probes.group_found(Probes.start_event(), "x", %Toddy.Group{id: 1, title: "x"})
      end)

    assert info_only_log == ""
  end

  test "download_batch_completed/3 summarizes a batch as one wide event, not one per item" do
    downloads = [
      %Toddy.Download{remote_file_id: "a", destination_path: "/tmp/a", status: :completed},
      %Toddy.Download{remote_file_id: "b", destination_path: "/tmp/b", status: :failed}
    ]

    log =
      capture_log(fn ->
        Probes.download_batch_completed(Probes.start_event(), downloads, :date)
      end)

    lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "toddy.wide_event"))
    assert length(lines) == 1
    assert hd(lines) =~ "event=download_batch"
    assert hd(lines) =~ "total=2"
    assert hd(lines) =~ "completed=1"
    assert hd(lines) =~ "failed=1"
    assert hd(lines) =~ "group_by=date"
  end

  test "rate_limited/1 is a standalone instantaneous wide event" do
    log = capture_log(fn -> Probes.rate_limited(5) end)
    assert log =~ "toddy.wide_event event=rate_limited"
    assert log =~ "retry_after_seconds=5"
  end
end
