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
      extra_applications: [:logger],
      mod: {ScipElixir.Application, []}
    ]
  end

  defp deps do
    [
      {:exqlite, "~> 0.27"},
      {:gen_lsp, "~> 0.11"},
      {:rustler, "~> 0.37", runtime: false}
    ]
  end

  defp aliases do
    []
  end
end
