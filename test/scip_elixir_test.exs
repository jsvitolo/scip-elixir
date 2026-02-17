defmodule ScipElixirTest do
  use ExUnit.Case
  doctest ScipElixir

  test "greets the world" do
    assert ScipElixir.hello() == :world
  end
end
