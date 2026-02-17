defmodule ScipElixir.Release do
  @moduledoc """
  Release entry points for scip-elixir.

  These functions are called via `bin/scip_elixir eval` in the OTP release.
  Mix tasks are not available in releases, so we provide equivalent functions here.
  """

  @app :scip_elixir

  @doc "Start the LSP server on stdio. Blocks forever."
  def lsp do
    # Redirect logger to stderr so it doesn't pollute LSP stdio
    Logger.configure(level: :warning)

    {:ok, _pid} = ScipElixir.LSP.start_link([])

    # Keep the VM alive
    Process.sleep(:infinity)
  end

  @doc "Run the indexer on the current project."
  def index do
    {:ok, stats} = ScipElixir.Indexer.run()

    IO.puts(
      "[scip-elixir] Indexed: #{stats.symbols} symbols, #{stats.refs} refs across #{stats.files} files"
    )
  end

  @doc "Return the current version."
  def version do
    Application.spec(@app, :vsn) |> to_string()
  end
end
