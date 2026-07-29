defmodule IcedExample.RekindleClientTest do
  use ExUnit.Case, async: false

  @tag :rust
  @tag timeout: :infinity
  test "Rust client" do
    Rekindle.Test.run!(:iced_example)
  end
end
