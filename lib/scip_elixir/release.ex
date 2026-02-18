defmodule ScipElixir.Release do
  @moduledoc """
  Entry points for scip-elixir.

  These functions are called by the launcher script via `elixir -pa <ebins>`.
  System Elixir provides Mix and the compiler. The release's lib/ directory
  contains only scip-elixir and its dependencies (standard libs are stripped
  at build time).

  ## Architecture

  Unlike a traditional OTP release, scip-elixir runs on the system's Elixir
  installation (similar to elixir-ls). This means:

  - Mix is available for compiling user projects
  - No ERTS contamination (ROOTDIR, BINDIR, PATH pollution)
  - No version conflicts between bundled and system Elixir
  - Requires Elixir >= 1.17 on the system
  """

  require Logger

  @app :scip_elixir

  @doc "Start the LSP server on stdio. Blocks forever."
  def lsp do
    {:ok, _} = Application.ensure_all_started(:scip_elixir)

    Logger.configure(level: :warning)

    {:ok, _pid} = ScipElixir.LSP.start_link([])

    Process.sleep(:infinity)
  end

  @doc "Run the indexer on the current project."
  def index do
    {:ok, _} = Application.ensure_all_started(:scip_elixir)

    {:ok, stats} = ScipElixir.Indexer.run()
    print_stats(stats)
  end

  @doc """
  Index a project by shelling out to `elixir -S mix`.

  Used by the LSP for background indexing to avoid loading user code into
  the LSP's VM. Adds scip-elixir BEAM directories to the child process
  code path via `-pa`.

  Returns `{:ok, exit_code}` or `{:error, reason}`.
  """
  def index_via_shell(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    db_path = Keyword.get(opts, :db_path, ".scip-elixir/index.db")

    pa_args = release_pa_args()

    if pa_args == [] do
      IO.puts(:stderr, "[scip-elixir] Error: could not find BEAM files")
      {:error, :no_beams}
    else
      script = ~s|ScipElixir.Indexer.run(db_path: "#{db_path}")|

      args = pa_args ++ ["-S", "mix", "run", "--no-start", "-e", script]

      IO.puts(:stderr, "[scip-elixir] Indexing #{project_dir}...")

      port =
        Port.open({:spawn_executable, find_elixir!()}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args,
          cd: String.to_charlist(project_dir)
        ])

      collect_port_output(port)
    end
  end

  @doc "Return the current version."
  def version do
    Application.load(@app)
    Application.spec(@app, :vsn) |> to_string()
  end

  # --- Private ---

  defp print_stats(stats) do
    IO.puts(
      "[scip-elixir] Indexed: #{stats.symbols} symbols, #{stats.refs} refs across #{stats.files} files"
    )
  end

  # Build -pa arguments pointing to BEAM directories in the release's lib/.
  # Standard libs are stripped at build time, so all entries are deps.
  defp release_pa_args do
    case :code.lib_dir(:scip_elixir) do
      {:error, _} ->
        []

      lib_dir ->
        release_lib = lib_dir |> to_string() |> Path.dirname()

        case File.ls(release_lib) do
          {:ok, entries} ->
            entries
            |> Enum.map(&Path.join([release_lib, &1, "ebin"]))
            |> Enum.filter(&File.dir?/1)
            |> Enum.flat_map(&["-pa", &1])

          _ ->
            []
        end
    end
  end

  defp find_elixir! do
    case System.find_executable("elixir") do
      nil -> raise "elixir not found on PATH"
      path -> path
    end
  end

  defp collect_port_output(port) do
    collect_port_output(port, [])
  end

  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        IO.write(:stderr, data)
        collect_port_output(port, [data | acc])

      {^port, {:exit_status, 0}} ->
        {:ok, 0}

      {^port, {:exit_status, code}} ->
        IO.puts(:stderr, "[scip-elixir] Indexing failed (exit code #{code})")
        {:error, code}
    after
      300_000 ->
        Port.close(port)
        IO.puts(:stderr, "[scip-elixir] Indexing timed out after 5 minutes")
        {:error, :timeout}
    end
  end
end
