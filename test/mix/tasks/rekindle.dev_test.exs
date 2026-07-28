defmodule Mix.Tasks.Rekindle.DevTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Rekindle.Dev

  test "parses optional development targets" do
    assert Dev.parse_targets!([]) == nil
    assert Dev.parse_targets!(["web"]) == [:web]
    assert Dev.parse_targets!(["desktop"]) == [:desktop]
    assert Dev.parse_targets!(["desktop,web"]) == [:web, :desktop]
  end

  test "rejects invalid development targets" do
    assert_raise Mix.Error, fn -> Dev.parse_targets!(["native"]) end
    assert_raise Mix.Error, fn -> Dev.parse_targets!(["web", "desktop"]) end
    assert_raise Mix.Error, fn -> Dev.parse_targets!(["web,web"]) end
  end
end
