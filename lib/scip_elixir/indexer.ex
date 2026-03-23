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
        # 5. Trigger compilation via Mix instead of raw ParallelCompiler.
        #
        # Using Mix.Task.run("compile") instead of Kernel.ParallelCompiler.compile:
        #   - Writes BEAM to _build/ (OS can page out cold code, reducing RSS)
        #   - On subsequent runs only recompiles changed files (fast, low memory)
        #   - Handles protocol consolidation correctly (no doubled warnings)
        #   - Respects the tracer injected above via Code.put_compiler_option
        #
        # Use explicit project_root if provided — Mix may change cwd during compilation
        project_root = Keyword.get(opts, :project_root, File.cwd!())

        # Collect files needed for tree-sitter enrichment later
        files =
          [
            Path.wildcard(Path.join([project_root, "lib", "**", "*.ex"])),
            Path.wildcard(Path.join([project_root, "apps", "*", "lib", "**", "*.ex"]))
          ]
          |> List.flatten()
          |> Enum.uniq()

        Logger.info("[scip-elixir] Compiling #{length(files)} files with tracer...")

        # Suppress "redefining module" and "already consolidated" warnings.
        previous_ignore_conflict = Code.get_compiler_option(:ignore_module_conflict)
        Code.put_compiler_option(:ignore_module_conflict, true)

        try do
          # Reenable so this can run even if already invoked in this VM session.
          Mix.Task.reenable("compile")
          Mix.Task.reenable("elixir.compile")

          # --force: recompile all project files so tracer captures every module.
          # --no-deps-check: skip verifying deps (they're already on the code path).
          Mix.Task.run("compile", ["--force", "--no-deps-check"])
        after
          Code.put_compiler_option(:ignore_module_conflict, previous_ignore_conflict)
        end

        # 6. Get stats before flush
        stats = ScipElixir.Collector.stats()
        Logger.info("[scip-elixir] Collected #{stats.symbols} symbols and #{stats.refs} refs")

        # 7. Flush collected data to SQLite
        {:ok, saved} = ScipElixir.Collector.flush(store)
        Logger.info("[scip-elixir] Saved #{saved.symbols} symbols and #{saved.refs} refs to #{db_path}")

        # 8. Enrich with tree-sitter positions
        enriched = enrich_with_tree_sitter(store, files)
        Logger.info("[scip-elixir] Enriched #{enriched} symbols with precise positions via tree-sitter")

        # 9. Report final stats
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

  # Parse each file with tree-sitter and update symbol positions
  defp enrich_with_tree_sitter(store, files) do
    files
    |> Enum.reduce(0, fn file, count ->
      case File.read(file) do
        {:ok, source} ->
          defs = ScipElixir.TreeSitter.find_definitions(source)
          updated = update_symbol_positions(store, file, defs)
          count + updated

        {:error, _} ->
          count
      end
    end)
  end

  defp update_symbol_positions(store, file, defs) do
    # Get all symbols in this file
    symbols = ScipElixir.Store.symbols_in_file(store, file)

    # Match tree-sitter definitions to stored symbols by name+arity
    Enum.reduce(defs, 0, fn ts_def, count ->
      # Find matching symbol
      matching =
        Enum.find(symbols, fn sym ->
          matches_definition?(sym, ts_def)
        end)

      case matching do
        %{id: id} ->
          # tree-sitter lines are 0-based, store uses 1-based
          ScipElixir.Store.update_symbol_position(store, id,
            line: ts_def.line + 1,
            col: ts_def.col + 1,
            end_line: ts_def.end_line + 1,
            end_col: ts_def.end_col + 1
          )
          count + 1

        nil ->
          count
      end
    end)
  end

  defp matches_definition?(sym, ts_def) do
    cond do
      # Module match: kind is module, name matches
      ts_def.kind == "module" and sym[:kind] == "module" ->
        # Symbol name might be "Elixir.MyApp.Router" or "MyApp.Router"
        sym_name = sym[:name] || ""
        ts_name = ts_def.name

        String.ends_with?(sym_name, ts_name) or
          sym_name == "Elixir.#{ts_name}" or
          sym_name == ts_name

      # Function/macro match: name and arity match
      ts_def.kind in ["function", "macro"] ->
        sym_name = sym[:name] || ""
        sym_arity = sym[:arity]

        sym_name == ts_def.name and
          (sym_arity == ts_def.arity or
             # Handle catch-all: tree-sitter sees each clause, compiler sees one
             sym_name == ts_def.name)

      true ->
        false
    end
  end
end
