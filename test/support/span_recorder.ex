defmodule Toddy.Test.SpanRecorder do
  @moduledoc """
  Test-only `otel_exporter_traces` (opentelemetry SDK, `only: :test` dep)
  that forwards each finished span to whichever process registered itself
  as `:toddy_test_span_recorder`, so tests can assert on genuinely emitted
  span names/attributes instead of trusting that emission "didn't crash".

  Wired up as the sole processor/exporter via `config/config.exs` (`:test`
  env only) using `:otel_simple_processor`, which exports synchronously on
  `end_span` — no batching delay to race against in tests.
  """

  require Record

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  @behaviour :otel_exporter_traces

  @doc "Idempotent — a test that calls `capture_spans/1` more than once re-registers the same pid."
  def register do
    if Process.whereis(:toddy_test_span_recorder) != self() do
      Process.register(self(), :toddy_test_span_recorder)
    end

    :ok
  end

  @impl :otel_exporter_traces
  def init(_config), do: {:ok, []}

  @impl :otel_exporter_traces
  def export(tab, _resource, _config) do
    case Process.whereis(:toddy_test_span_recorder) do
      nil ->
        :ok

      pid ->
        tab
        |> :ets.tab2list()
        |> Enum.each(fn record ->
          span = %{
            name: span(record, :name),
            attributes: record |> span(:attributes) |> :otel_attributes.map(),
            status: record |> span(:status) |> status_code()
          }

          send(pid, {:otel_span, span})
        end)
    end

    :ok
  end

  defp status_code(:undefined), do: :unset
  defp status_code({:status, code, _message}), do: code

  @impl :otel_exporter_traces
  def shutdown(_), do: :ok
end
