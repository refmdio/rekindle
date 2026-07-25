defmodule Rekindle.ArchitectureTest do
  use ExUnit.Case, async: false

  test "the runtime module graph is acyclic" do
    project_root = Path.dirname(Path.expand(Mix.Project.project_file()))

    assert {output, 0} =
             System.cmd(
               System.find_executable("mix"),
               ["xref", "graph", "--format", "cycles"],
               cd: project_root,
               env: [{"MIX_ENV", "test"}],
               stderr_to_stdout: true
             )

    assert output == "No cycles found\n"
  end
end
