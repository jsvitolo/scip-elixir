defmodule ScipElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :scip_elixir,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:exqlite, "~> 0.27"}
    ]
  end

  defp aliases do
    []
  end
end
