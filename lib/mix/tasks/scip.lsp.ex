defmodule Mix.Tasks.Scip.Lsp do
  @moduledoc """
  Starts the scip-elixir LSP server.

  The server communicates over stdio using the Language Server Protocol.

  ## Usage

      mix scip.lsp [--db PATH]

  ## Options

    - `--db PATH` — Path to the SQLite database (default: `.scip-elixir/index.db`)

  ## Examples

      # Start LSP server (reads index from default path)
      mix scip.lsp

      # Custom database path
      mix scip.lsp --db /path/to/index.db
  """

  use Mix.Task

  @shortdoc "Start the scip-elixir LSP server"

  @switches [db: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, switches: @switches)

    lsp_opts =
      case Keyword.get(opts, :db) do
        nil -> []
        path -> [db_path: path]
      end

    {:ok, _pid} = ScipElixir.LSP.start_link(lsp_opts)

    # Keep the process alive
    Process.sleep(:infinity)
  end
end
