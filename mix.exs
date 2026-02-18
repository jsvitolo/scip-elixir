defmodule ScipElixir.MixProject do
  use Mix.Project

  @version "0.1.3"

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
        include_erts: true,
        include_executables_for: [:unix],
        steps: [:assemble, &copy_wrapper/1, :tar]
      ]
    ]
  end

  # Copy the scip-elixir wrapper script into the release bin/ directory
  defp copy_wrapper(release) do
    bin_dir = Path.join(release.path, "bin")

    wrapper = ~S"""
    #!/bin/sh
    set -e

    # Resolve symlinks so RELEASE_ROOT is correct when invoked via symlink
    SELF="$0"
    if [ -L "$SELF" ]; then
      LINK="$(readlink "$SELF")"
      case "$LINK" in /*) SELF="$LINK" ;; *) SELF="$(dirname "$SELF")/$LINK" ;; esac
    fi
    SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
    RELEASE_ROOT="$(dirname "$SCRIPT_DIR")"

    export RELEASE_ROOT
    export RELEASE_NAME="scip_elixir"
    export RELEASE_VSN="${RELEASE_VSN:-$(cat "$RELEASE_ROOT/releases/start_erl.data" | cut -d' ' -f2)}"
    export RELEASE_COMMAND="eval"

    case "$1" in
      lsp|--stdio|"")
        exec "$RELEASE_ROOT/bin/scip_elixir" eval "ScipElixir.Release.lsp()"
        ;;
      index)
        shift
        exec "$RELEASE_ROOT/bin/scip_elixir" eval "ScipElixir.Release.index()"
        ;;
      version)
        exec "$RELEASE_ROOT/bin/scip_elixir" eval "IO.puts(ScipElixir.Release.version())"
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
