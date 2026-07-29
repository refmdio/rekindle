defmodule GpuiExample.RekindleClientTest do
  use ExUnit.Case, async: false

  @tag :rust
  @tag timeout: :infinity
  test "Rust client" do
    Rekindle.Test.run!(:gpui_example)
  end
end
