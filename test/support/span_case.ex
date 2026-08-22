defmodule Toddy.SpanCase do
  @moduledoc """
  Test helper for asserting on genuinely emitted OpenTelemetry spans.
  Constitution Principle VIII wide events are OTel-only (no `Logger`
  fallback), so tests must capture real spans rather than log output.
  """

  alias Toddy.Test.SpanRecorder

  @doc """
  Registers the calling process to receive every span emitted while running
  `fun` (via `Toddy.Test.SpanRecorder`, wired up as the sole exporter for
  `:test` in `config/config.exs`, using the synchronous
  `:otel_simple_processor` so spans land before `fun` returns), then returns
  every captured `%{name:, attributes:, status:}` map in emission order.
  """
  def capture_spans(fun) do
    SpanRecorder.register()
    fun.()
    drain([])
  end

  defp drain(acc) do
    receive do
      {:otel_span, span} -> drain([span | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
