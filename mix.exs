defmodule Toddy.MixProject do
  use Mix.Project

  def project do
    [
      app: :toddy,
      version: "0.1.0",
      elixir: "=> 1.19.5",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

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
      {:mox, "~> 1.1", only: :test}
    ]
  end
end
