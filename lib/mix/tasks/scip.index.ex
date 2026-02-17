defmodule Mix.Tasks.Scip.Index do
  @moduledoc """
  Indexes the current Elixir project using compiler tracers and stores
  the results in a SQLite database for fast code intelligence queries.

  ## Usage

      mix scip.index [--force] [--db PATH]

  ## Options

    - `--force` — Force recompilation of all files
    - `--db PATH` — Path to the SQLite database (default: `.scip-elixir/index.db`)

  ## Examples

      # Index the project (incremental)
      mix scip.index

      # Force full re-index
      mix scip.index --force

      # Custom database path
      mix scip.index --db /tmp/my_index.db
  """

  use Mix.Task

  @shortdoc "Index the project for code intelligence"

  @switches [force: :boolean, db: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, switches: @switches)

    indexer_opts = [
      force: Keyword.get(opts, :force, false),
      db_path: Keyword.get(opts, :db, ".scip-elixir/index.db")
    ]

    # Ensure the project is loaded
    Mix.Task.run("loadpaths")

    case ScipElixir.Indexer.run(indexer_opts) do
      {:ok, stats} ->
        Mix.shell().info("""
        scip-elixir indexing complete!
          Symbols: #{stats.symbols}
          Refs:    #{stats.refs}
          Files:   #{stats.files}
        """)

      {:error, reason} ->
        Mix.shell().error("scip-elixir indexing failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
