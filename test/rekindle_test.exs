defmodule RekindleTest do
  use ExUnit.Case, async: true

  test "loads the public module" do
    assert Rekindle.module_info(:module) == Rekindle
  end
end
