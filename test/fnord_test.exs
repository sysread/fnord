defmodule FnordTest do
  use ExUnit.Case
  doctest Fnord

  test "greets the world" do
    assert Fnord.hello() == :world
  end
end
