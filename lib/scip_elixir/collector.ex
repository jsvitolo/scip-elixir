defmodule ScipElixir.Collector do
  @moduledoc """
  Collects symbols and references from the compiler tracer.

  Acts as an in-memory buffer during compilation. After compilation completes,
  the collected data is flushed to the SQLite database via `flush/1`.

  Uses an ETS table for lock-free concurrent writes from the compiler tracer
  (which may run on multiple scheduler threads).
  """

  use GenServer

  @table :scip_elixir_collector

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Add a symbol definition (module, function, macro, type)."
  def add_symbol(symbol) do
    :ets.insert(@table, {:symbol, System.monotonic_time(:nanosecond), symbol})
    :ok
  end

  @doc "Add a reference (function call, alias, import, struct usage)."
  def add_ref(ref) do
    :ets.insert(@table, {:ref, System.monotonic_time(:nanosecond), ref})
    :ok
  end

  @doc "Flush all collected data to the given store and clear the buffer."
  def flush(store) do
    GenServer.call(__MODULE__, {:flush, store}, :infinity)
  end

  @doc "Get counts of collected symbols and refs (for diagnostics)."
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc "Clear all collected data without flushing."
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :bag, :public, write_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:flush, store}, _from, state) do
    symbols = drain(:symbol)
    refs = drain(:ref)

    result = ScipElixir.Store.save(store, symbols, refs)

    {:reply, result, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    symbols = :ets.match(@table, {:symbol, :_, :"$1"}) |> length()
    refs = :ets.match(@table, {:ref, :_, :"$1"}) |> length()
    {:reply, %{symbols: symbols, refs: refs}, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # --- Private ---

  defp drain(type) do
    entries = :ets.match(@table, {type, :_, :"$1"})
    :ets.match_delete(@table, {type, :_, :_})
    List.flatten(entries)
  end
end
