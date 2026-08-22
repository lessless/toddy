defmodule Toddy.MixProject do
  use Mix.Project

  def project do
    [
      app: :toddy,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Toddy.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:zigler, "~> 0.16", runtime: false},
      {:jason, "~> 1.4"},
      {:opentelemetry_api, "~> 1.4"},
      {:mox, "~> 1.1", only: :test},
      {:opentelemetry, "~> 1.5", only: :test}
    ]
  end
end
