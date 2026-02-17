defmodule ScipElixir.TreeSitterTest do
  use ExUnit.Case

  alias ScipElixir.TreeSitter

  @sample_source """
  defmodule MyApp.Accounts do
    @moduledoc "Accounts context"

    def get_user(id) do
      Repo.get(User, id)
    end

    def list_users do
      Repo.all(User)
    end

    defp secret_function(a, b, c) do
      a + b + c
    end

    defmacro my_macro(expr) do
      quote do: unquote(expr)
    end

    defstruct [:name, :email]
  end
  """

  describe "parse/1" do
    test "returns S-expression for valid Elixir" do
      sexp = TreeSitter.parse(@sample_source)
      assert is_binary(sexp)
      assert String.starts_with?(sexp, "(source")
      assert String.contains?(sexp, "call")
    end

    test "handles empty source" do
      sexp = TreeSitter.parse("")
      assert sexp == "(source)"
    end
  end

  describe "find_definitions/1" do
    test "finds module definition" do
      defs = TreeSitter.find_definitions(@sample_source)
      modules = Enum.filter(defs, &(&1.kind == "module"))

      assert length(modules) == 1
      assert hd(modules).name == "MyApp.Accounts"
      assert hd(modules).line == 0
    end

    test "finds function definitions with correct arity" do
      defs = TreeSitter.find_definitions(@sample_source)
      functions = Enum.filter(defs, &(&1.kind == "function"))

      names = Enum.map(functions, &{&1.name, &1.arity})
      assert {"get_user", 1} in names
      assert {"list_users", 0} in names
      assert {"secret_function", 3} in names
    end

    test "finds macro definitions" do
      defs = TreeSitter.find_definitions(@sample_source)
      macros = Enum.filter(defs, &(&1.kind == "macro"))

      assert length(macros) == 1
      assert hd(macros).name == "my_macro"
      assert hd(macros).arity == 1
    end

    test "finds struct definitions" do
      defs = TreeSitter.find_definitions(@sample_source)
      structs = Enum.filter(defs, &(&1.kind == "struct"))

      assert length(structs) == 1
      assert hd(structs).name == "__struct__"
    end

    test "provides precise line positions" do
      defs = TreeSitter.find_definitions(@sample_source)
      get_user = Enum.find(defs, &(&1.name == "get_user"))

      assert get_user.line == 3
      assert get_user.col == 2
      assert get_user.end_line == 5
    end

    test "handles multiple clauses of same function" do
      source = """
      defmodule M do
        def greet(:en), do: "Hello"
        def greet(:pt), do: "Olá"
        def greet(:es), do: "Hola"
      end
      """

      defs = TreeSitter.find_definitions(source)
      greets = Enum.filter(defs, &(&1.name == "greet"))

      # Each clause is a separate definition
      assert length(greets) == 3
    end

    test "handles guards" do
      source = """
      defmodule M do
        def positive(x) when x > 0, do: x
      end
      """

      defs = TreeSitter.find_definitions(source)
      positives = Enum.filter(defs, &(&1.name == "positive"))

      assert length(positives) == 1
      assert hd(positives).arity == 1
    end
  end

  describe "node_at_position/3" do
    test "finds alias at module name position" do
      node = TreeSitter.node_at_position(@sample_source, 0, 11)

      assert node.kind == "alias"
      assert node.text == "MyApp.Accounts"
    end

    test "finds identifier at function name" do
      # Line 3: def get_user(id) do
      node = TreeSitter.node_at_position(@sample_source, 3, 6)

      assert node.kind == "identifier"
      assert node.text == "get_user"
    end

    test "finds identifier at argument" do
      # Line 3: def get_user(id) do
      node = TreeSitter.node_at_position(@sample_source, 3, 15)

      assert node.kind == "identifier"
      assert node.text == "id"
    end

    test "finds alias in function body" do
      # Line 4: Repo.get(User, id)
      node = TreeSitter.node_at_position(@sample_source, 4, 4)

      assert node.kind == "alias"
      assert node.text == "Repo"
    end

    test "returns parent kind for context" do
      node = TreeSitter.node_at_position(@sample_source, 3, 6)
      assert is_binary(node.parent_kind)
    end
  end

  describe "parse_heex/1" do
    test "parses HEEx template" do
      heex = """
      <div class="container">
        <p><%= @name %></p>
      </div>
      """

      sexp = TreeSitter.parse_heex(heex)
      assert is_binary(sexp)
      assert String.contains?(sexp, "tag")
    end

    test "parses LiveView components" do
      heex = """
      <.live_component module={MyComponent} id="foo" />
      """

      sexp = TreeSitter.parse_heex(heex)
      assert String.contains?(sexp, "component")
    end
  end
end
