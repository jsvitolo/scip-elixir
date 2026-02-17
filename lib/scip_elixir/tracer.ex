defmodule ScipElixir.Tracer do
  @moduledoc """
  Compiler tracer that captures semantic events during compilation.

  Implements the Elixir compiler tracer behaviour (available since Elixir 1.10).
  Captures function calls, macro usage, alias references, module definitions,
  and stores them via the ScipElixir.Collector.

  ## Events captured

  - `:remote_function` — module X called function Y from module Z
  - `:remote_macro` — module X used macro Y from module Z
  - `:imported_function` — module X called imported function Y
  - `:imported_macro` — module X used imported macro Y
  - `:alias_reference` — module X referenced alias Y
  - `:alias_expansion` — alias expanded to full module name
  - `:on_module` — module definition complete (with bytecode and definitions)
  - `:struct_expansion` — struct literal expanded
  """

  @doc """
  Handles a compiler trace event.

  Called by the Elixir compiler for each trace event when this module
  is registered as a tracer via `Code.put_compiler_option(:tracers, [ScipElixir.Tracer])`.
  """
  def trace({:remote_function, meta, module, name, arity}, env) do
    record_ref(meta, env, module, name, arity, :function)
  end

  def trace({:remote_macro, meta, module, name, arity}, env) do
    record_ref(meta, env, module, name, arity, :macro)
  end

  def trace({:imported_function, meta, module, name, arity}, env) do
    record_ref(meta, env, module, name, arity, :import)
  end

  def trace({:imported_macro, meta, module, name, arity}, env) do
    record_ref(meta, env, module, name, arity, :import)
  end

  def trace({:alias_reference, meta, module}, env) do
    line = Keyword.get(meta, :line, 0)
    col = Keyword.get(meta, :column, 0)
    file = env.file

    ScipElixir.Collector.add_ref(%{
      file: file,
      line: line,
      column: col,
      target_module: inspect(module),
      target_name: nil,
      target_arity: nil,
      kind: :alias
    })

    :ok
  end

  def trace({:struct_expansion, meta, module, _keys}, env) do
    line = Keyword.get(meta, :line, 0)
    col = Keyword.get(meta, :column, 0)
    file = env.file

    ScipElixir.Collector.add_ref(%{
      file: file,
      line: line,
      column: col,
      target_module: inspect(module),
      target_name: "__struct__",
      target_arity: 0,
      kind: :struct
    })

    :ok
  end

  def trace({:on_module, _bytecode, _}, env) do
    file = env.file
    module = env.module
    line = env.line

    # Record module definition
    ScipElixir.Collector.add_symbol(%{
      name: inspect(module),
      kind: :module,
      module: parent_module(module),
      file: file,
      line: line,
      column: 1,
      arity: nil,
      documentation: nil
    })

    # Record all function definitions from the module
    if Code.ensure_loaded?(module) do
      record_module_definitions(module, file)
    end

    :ok
  end

  # Catch-all for events we don't handle
  def trace(_event, _env), do: :ok

  # --- Private helpers ---

  defp record_ref(meta, env, module, name, arity, kind) do
    line = Keyword.get(meta, :line, 0)
    col = Keyword.get(meta, :column, 0)
    file = env.file

    ScipElixir.Collector.add_ref(%{
      file: file,
      line: line,
      column: col,
      target_module: inspect(module),
      target_name: to_string(name),
      target_arity: arity,
      kind: kind
    })

    :ok
  end

  defp record_module_definitions(module, file) do
    # Get all function definitions from the module
    if function_exported?(module, :__info__, 1) do
      for {name, arity} <- module.__info__(:functions) do
        ScipElixir.Collector.add_symbol(%{
          name: to_string(name),
          kind: :function,
          module: inspect(module),
          file: file,
          line: 0,
          column: 0,
          arity: arity,
          documentation: nil
        })
      end

      for {name, arity} <- module.__info__(:macros) do
        ScipElixir.Collector.add_symbol(%{
          name: to_string(name),
          kind: :macro,
          module: inspect(module),
          file: file,
          line: 0,
          column: 0,
          arity: arity,
          documentation: nil
        })
      end
    end
  end

  defp parent_module(module) do
    parts = Module.split(module)

    case parts do
      [_single] -> nil
      parts -> parts |> Enum.slice(0..-2//1) |> Enum.join(".")
    end
  end
end
