defmodule Rekindle.PhoenixTest do
  use ExUnit.Case, async: true

  defmodule Endpoint do
    def static_path(path), do: "/digest#{path}"
  end

  defmodule DevelopmentEndpoint do
    def config(:code_reloader), do: true
    def static_path(path), do: path
  end

  test "resolves the production Web entry module through the Phoenix endpoint" do
    assert Rekindle.Phoenix.web_entry_path(Endpoint) ==
             "/digest/rekindle/entry.js"
  end

  test "selects the development runtime when code reloading is enabled" do
    assert Rekindle.Phoenix.web_entry_path(DevelopmentEndpoint) ==
             "/@rekindle/runtime.js"
  end
end
