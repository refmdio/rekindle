defmodule Rekindle.PhoenixTest do
  use ExUnit.Case, async: true

  defmodule Endpoint do
    def static_path(path), do: "/digest#{path}"
  end

  test "resolves the Web entry module through the Phoenix endpoint" do
    assert Rekindle.Phoenix.web_entry_path(Endpoint) ==
             "/digest/rekindle/entry.js"
  end
end
