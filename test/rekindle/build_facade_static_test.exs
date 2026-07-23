defmodule Rekindle.BuildFacadeStaticTest do
  use ExUnit.Case, async: true

  test "the public build surface has one source owner" do
    root = File.cwd!()

    facade_modules =
      Path.wildcard(Path.join(root, "lib/**/*.ex"))
      |> Enum.filter(&(File.read!(&1) =~ ~r/^defmodule Rekindle do$/m))

    assert facade_modules == [Path.join(root, "lib/rekindle.ex")]

    facade_source = File.read!(hd(facade_modules))
    assert length(Regex.scan(~r/^  def build\(/m, facade_source)) == 1
    assert length(Regex.scan(~r/^  def current\(/m, facade_source)) == 1
    assert {:module, Rekindle} = Code.ensure_loaded(Rekindle)
    assert function_exported?(Rekindle, :build, 3)
    refute function_exported?(Rekindle, :build, 2)
    assert function_exported?(Rekindle, :current, 2)

    task_owners =
      Path.wildcard(Path.join(root, "lib/**/*.ex"))
      |> Enum.filter(&(File.read!(&1) =~ "defmodule Mix.Tasks.Rekindle.Build do"))

    assert task_owners == [Path.join(root, "lib/mix/tasks/rekindle.build.ex")]
  end

  test "target handlers cannot own activation or public facade functions" do
    source = File.read!(Path.join(File.cwd!(), "lib/rekindle/target_handler.ex"))

    assert source =~ "@callback build("
    refute source =~ "@callback current("
    refute source =~ "@callback activate("
    refute source =~ "@callback project("
    refute source =~ "@callback export("
  end
end
