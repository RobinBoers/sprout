defmodule SproutdTest do
  use ExUnit.Case
  doctest Sproutd

  test "greets the world" do
    assert Sproutd.hello() == :world
  end
end
