defmodule ScipElixir.Indexer do
  @moduledoc """
  Orchestrates the indexing process: starts the collector, injects the compiler
  tracer, triggers compilation, and flushes results to the SQLite store.
  """

  require Logger

  @default_db_path ".scip-elixir/index.db"

  @doc """
  Run the full indexing pipeline for the current project.

  Options:
    - `:db_path` — path to the SQLite database (default: `.scip-elixir/index.db`)
    - `:force` — force recompilation of all files (default: `false`)
  """
  def run(opts \\ []) do
    db_path = Keyword.get(opts, :db_path, @default_db_path)
    force = Keyword.get(opts, :force, false)

    # Ensure directory exists
    db_path |> Path.dirname() |> File.mkdir_p!()

    Logger.info("[scip-elixir] Starting indexing...")

    # 1. Open the store
    {:ok, store} = ScipElixir.Store.open(db_path)

    try do
      # 2. Clear existing data if force recompile
      if force do
        ScipElixir.Store.clear_all(store)
      end

      # 3. Start the collector
      {:ok, _pid} = ScipElixir.Collector.start_link()

      # 4. Inject our tracer into the compiler
      previous_tracers = Code.get_compiler_option(:tracers)
      Code.put_compiler_option(:tracers, [ScipElixir.Tracer | previous_tracers])

      try do
        # 5. Trigger compilation
        # We use Kernel.ParallelCompiler directly because mix compile
        # may skip recompilation in the same VM session even with --force.
        # First ensure deps are compiled via mix.
        Mix.Task.run("compile", [])

        # Then recompile project files with our tracer active
        project_root = File.cwd!()
        files = Path.wildcard(Path.join([project_root, "lib", "**", "*.ex"]))
        Logger.info("[scip-elixir] Compiling #{length(files)} files with tracer...")

        Kernel.ParallelCompiler.compile(files)

        # 6. Get stats before flush
        stats = ScipElixir.Collector.stats()
        Logger.info("[scip-elixir] Collected #{stats.symbols} symbols and #{stats.refs} refs")

        # 7. Flush collected data to SQLite
        {:ok, saved} = ScipElixir.Collector.flush(store)
        Logger.info("[scip-elixir] Saved #{saved.symbols} symbols and #{saved.refs} refs to #{db_path}")

        # 8. Report final stats
        db_stats = ScipElixir.Store.stats(store)
        Logger.info("[scip-elixir] Index: #{db_stats.symbols} symbols, #{db_stats.refs} refs across #{db_stats.files} files")

        {:ok, db_stats}
      after
        # Restore original tracers
        Code.put_compiler_option(:tracers, previous_tracers)

        # Stop the collector
        if Process.whereis(ScipElixir.Collector) do
          GenServer.stop(ScipElixir.Collector)
        end
      end
    after
      ScipElixir.Store.close(store)
    end
  end
end
