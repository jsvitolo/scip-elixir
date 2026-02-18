defmodule ScipElixir.Release do
  @moduledoc """
  Release entry points for scip-elixir.

  These functions are called via `bin/scip_elixir eval` in the OTP release.
  Mix tasks are not available in releases, so we provide equivalent functions here.

  For indexing, the release shells out to `elixir -S mix` with the release's
  BEAM files on the code path, since Mix is required for compilation.
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

    if Code.ensure_loaded?(Mix) do
      # Mix available (dev mode or escript) — index directly
      {:ok, stats} = ScipElixir.Indexer.run()
      print_stats(stats)
    else
      # Release mode — shell out to elixir with our BEAMs on the code path
      index_via_shell()
    end
  end

  @doc """
  Index a project by shelling out to `elixir -S mix`.

  Used when Mix is not available (release binary). Adds the release's BEAM
  directories to the code path via `-pa` so ScipElixir modules are available
  during compilation.

  Returns `{:ok, exit_code}`.
  """
  def index_via_shell(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    db_path = Keyword.get(opts, :db_path, ".scip-elixir/index.db")

    pa_args = release_pa_args()

    if pa_args == [] do
      IO.puts(:stderr, "[scip-elixir] Error: could not find release BEAM files")
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
    Application.spec(@app, :vsn) |> to_string()
  end

  # --- Private ---

  defp print_stats(stats) do
    IO.puts(
      "[scip-elixir] Indexed: #{stats.symbols} symbols, #{stats.refs} refs across #{stats.files} files"
    )
  end

  # Build -pa arguments pointing to all BEAM directories in the release's lib/
  defp release_pa_args do
    case :code.lib_dir(:scip_elixir) do
      {:error, _} ->
        []

      lib_dir ->
        # lib_dir is like /path/to/lib/scip_elixir-0.1.0
        # parent is /path/to/lib/
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
