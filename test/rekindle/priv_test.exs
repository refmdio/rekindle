defmodule Rekindle.PrivTest do
  use ExUnit.Case, async: true

  test "resolves and reads files below an OTP priv root" do
    source = {:rekindle, "templates/client/gpui"}

    assert Rekindle.Priv.path(source, "src/lib.rs") ==
             Application.app_dir(:rekindle, "priv/templates/client/gpui/src/lib.rs")

    assert Rekindle.Priv.read!(source, "src/lib.rs") =~ "pub struct HelloWorld"
  end

  test "rejects paths outside the selected priv root" do
    assert_raise ArgumentError, fn ->
      Rekindle.Priv.path({:rekindle, "templates/client"}, "../mix.exs")
    end

    assert_raise ArgumentError, fn ->
      Rekindle.Priv.path(:rekindle, "/tmp/source.rs")
    end
  end
end
