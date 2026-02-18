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

  # Standard Elixir/OTP apps bundled in the release that should NOT be
  # added to -pa (the system Elixir already has them, and mixing versions
  # causes crashes like :elixir_quote.shallow_validate_ast/1 undefined).
  @otp_apps ~w(
    asn1 compiler crypto elixir eunit iex inets kernel logger
    mix mnesia observer parsetools public_key sasl ssl stdlib
    syntax_tools tools wx xmerl
  )

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
  during compilation. Standard Elixir/OTP libraries are excluded from -pa
  to avoid version conflicts with the system Elixir.

  The child process environment is sanitized to remove release-specific
  variables (ROOTDIR, BINDIR, RELEASE_*, ERL_FLAGS) and PATH entries that
  point to the release's ERTS, preventing the system `erl` from being
  shadowed by the release's `erl`.

  Returns `{:ok, exit_code}` or `{:error, reason}`.
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
          cd: String.to_charlist(project_dir),
          env: clean_env()
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

  # Build -pa arguments pointing to scip_elixir dependency BEAM directories.
  # Excludes standard Elixir/OTP libraries to avoid version conflicts.
  defp release_pa_args do
    case :code.lib_dir(:scip_elixir) do
      {:error, _} ->
        []

      lib_dir ->
        release_lib = lib_dir |> to_string() |> Path.dirname()

        case File.ls(release_lib) do
          {:ok, entries} ->
            entries
            |> Enum.filter(&dep_entry?/1)
            |> Enum.map(&Path.join([release_lib, &1, "ebin"]))
            |> Enum.filter(&File.dir?/1)
            |> Enum.flat_map(&["-pa", &1])

          _ ->
            []
        end
    end
  end

  # Returns true if a lib/ entry is a project dependency (not standard OTP/Elixir).
  # Entry format: "app_name-version" e.g. "scip_elixir-0.1.3", "elixir-1.17.3"
  defp dep_entry?(entry) do
    app_name = entry |> String.split("-") |> List.first()
    app_name not in @otp_apps
  end

  # Build a clean environment for the child process, removing release-specific
  # variables and PATH entries that would cause the system erl to be shadowed.
  defp clean_env do
    release_root = System.get_env("RELEASE_ROOT") || ""

    # Remove release-specific dirs from PATH
    clean_path =
      System.get_env("PATH", "")
      |> String.split(":")
      |> Enum.reject(fn dir -> release_root != "" and String.starts_with?(dir, release_root) end)
      |> Enum.join(":")

    [
      # Set cleaned PATH
      {~c"PATH", String.to_charlist(clean_path)},
      # Remove ERTS/release env vars that contaminate child erl
      {~c"ROOTDIR", false},
      {~c"BINDIR", false},
      {~c"EMU", false},
      {~c"PROGNAME", false},
      # Remove release-specific vars
      {~c"RELEASE_ROOT", false},
      {~c"RELEASE_NAME", false},
      {~c"RELEASE_VSN", false},
      {~c"RELEASE_COMMAND", false},
      {~c"RELEASE_COOKIE", false},
      {~c"RELEASE_MODE", false},
      {~c"RELEASE_NODE", false},
      {~c"RELEASE_TMP", false},
      {~c"RELEASE_VM_ARGS", false},
      {~c"RELEASE_REMOTE_VM_ARGS", false},
      {~c"RELEASE_BOOT_SCRIPT", false},
      {~c"RELEASE_BOOT_SCRIPT_CLEAN", false},
      {~c"RELEASE_DISTRIBUTION", false},
      {~c"RELEASE_SYS_CONFIG", false},
      {~c"RELEASE_PROG", false},
      # Remove ERL_FLAGS set by env.sh (-noshell is already added by elixir)
      {~c"ERL_FLAGS", false},
      {~c"ELIXIR_ERL_OPTIONS", false}
    ]
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
