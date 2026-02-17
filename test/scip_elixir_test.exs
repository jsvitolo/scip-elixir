defmodule ScipElixirTest do
  use ExUnit.Case

  test "store can be opened and queried" do
    db_path = Path.join(System.tmp_dir!(), "scip_elixir_test_#{:rand.uniform(100_000)}.db")

    {:ok, store} = ScipElixir.Store.open(db_path)
    stats = ScipElixir.Store.stats(store)

    assert stats.symbols == 0
    assert stats.refs == 0
    assert stats.files == 0

    ScipElixir.Store.close(store)
    File.rm(db_path)
  end
end
