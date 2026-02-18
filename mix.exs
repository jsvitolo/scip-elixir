defmodule ScipElixir.MixProject do
  use Mix.Project

  @version "0.1.6"

  def project do
    [
      app: :scip_elixir,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
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

  defp releases do
    [
      scip_elixir: [
        include_erts: false,
        include_executables_for: [:unix],
        steps: [:assemble, &strip_std_libs/1, &copy_wrapper/1, :tar]
      ]
    ]
  end

  # Remove standard Elixir/OTP libraries from the release.
  # The wrapper script uses system Elixir which provides these.
  # Stripping avoids version conflicts and reduces archive size.
  @std_libs ~w(
    asn1 compiler crypto elixir eex eunit hex iex inets kernel logger
    mix mnesia observer parsetools public_key sasl ssl stdlib
    syntax_tools tools wx xmerl
  )

  defp strip_std_libs(release) do
    lib_dir = Path.join(release.path, "lib")

    File.ls!(lib_dir)
    |> Enum.each(fn entry ->
      app_name = entry |> String.split("-") |> List.first()

      if app_name in @std_libs do
        Path.join(lib_dir, entry) |> File.rm_rf!()
      end
    end)

    release
  end

  # Write the scip-elixir launcher script that uses system Elixir.
  # Unlike OTP release scripts, this requires Elixir to be installed
  # on the system (like elixir-ls). This ensures Mix is available for
  # compiling user projects during indexing.
  defp copy_wrapper(release) do
    bin_dir = Path.join(release.path, "bin")

    wrapper = ~S"""
    #!/bin/sh
    set -e

    # Resolve symlinks so paths are correct when invoked via symlink
    SELF="$0"
    if [ -L "$SELF" ]; then
      LINK="$(readlink "$SELF")"
      case "$LINK" in /*) SELF="$LINK" ;; *) SELF="$(dirname "$SELF")/$LINK" ;; esac
    fi
    SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
    ROOT="$(dirname "$SCRIPT_DIR")"

    # Require system Elixir (provides Mix, compiler, standard libs)
    if ! command -v elixir >/dev/null 2>&1; then
      echo "Error: elixir not found on PATH." >&2
      echo "scip-elixir requires Elixir >= 1.17 to be installed." >&2
      echo "Install via: https://elixir-lang.org/install.html" >&2
      exit 1
    fi

    # Build -pa args for all ebin dirs (std libs are stripped at build time)
    PA_ARGS=""
    EBIN_LIST=""
    for ebin in "$ROOT"/lib/*/ebin; do
      if [ -d "$ebin" ]; then
        PA_ARGS="$PA_ARGS -pa $ebin"
        EBIN_LIST="$EBIN_LIST\"$ebin\","
      fi
    done
    EBIN_LIST="${EBIN_LIST%,}"

    case "$1" in
      lsp|--stdio|"")
        exec elixir $PA_ARGS --no-halt -e "ScipElixir.Release.lsp()"
        ;;
      index)
        # mix run resets the code path, so we prepend paths in the script
        exec elixir -S mix run --no-start -e "[$EBIN_LIST] |> Enum.each(&Code.prepend_path/1); ScipElixir.Release.index()"
        ;;
      version)
        exec elixir $PA_ARGS -e "IO.puts(ScipElixir.Release.version())"
        ;;
      *)
        echo "Usage: scip-elixir [lsp|index|version]"
        echo ""
        echo "Commands:"
        echo "  lsp      Start the LSP server on stdio (default)"
        echo "  index    Run the indexer on the current project"
        echo "  version  Print version"
        exit 1
        ;;
    esac
    """

    wrapper_path = Path.join(bin_dir, "scip-elixir")
    File.write!(wrapper_path, wrapper)
    File.chmod!(wrapper_path, 0o755)

    release
  end
end
