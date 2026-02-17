defmodule ScipElixir.TreeSitter do
  @moduledoc """
  Tree-sitter NIF for parsing Elixir source code.

  Provides fast, incremental parsing of Elixir and HEEx source files
  using tree-sitter grammars compiled as Rust NIFs via Rustler.

  ## Functions

  - `parse/1` — Parse source and return S-expression tree
  - `find_definitions/1` — Extract all definitions with precise positions
  - `node_at_position/3` — Find the node at a cursor position
  - `parse_heex/1` — Parse HEEx template source
  """

  use Rustler, otp_app: :scip_elixir, crate: "treesitter_nif"

  @doc """
  Parse Elixir source code and return the S-expression of the parse tree.
  """
  def parse(_source_code), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Extract all definitions (modules, functions, macros) from Elixir source.

  Returns a list of `%ScipElixir.TreeSitter.Definition{}` structs with
  precise line/col positions.
  """
  def find_definitions(_source_code), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Find the most specific named node at a given position.

  Line and column are 0-based.

  Returns a `%ScipElixir.TreeSitter.NodeInfo{}` struct.
  """
  def node_at_position(_source_code, _line, _col), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Parse HEEx template source and return the S-expression of the parse tree.
  """
  def parse_heex(_source_code), do: :erlang.nif_error(:nif_not_loaded)
end

defmodule ScipElixir.TreeSitter.Definition do
  @moduledoc "A definition extracted from source code by tree-sitter."
  defstruct [:kind, :name, :arity, :line, :col, :end_line, :end_col]
end

defmodule ScipElixir.TreeSitter.NodeInfo do
  @moduledoc "Information about a tree-sitter node at a given position."
  defstruct [:kind, :text, :line, :col, :end_line, :end_col, :parent_kind]
end
