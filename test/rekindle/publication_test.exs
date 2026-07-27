defmodule Rekindle.PublicationTest do
  use ExUnit.Case, async: true

  alias Rekindle.Publication

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-publication-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "reserves distinct temporary files and directories", %{root: root} do
    assert {:ok, first_file} = Publication.temporary_file(root)
    assert {:ok, second_file} = Publication.temporary_file(root)
    assert {:ok, first_directory} = Publication.temporary_directory(root)
    assert {:ok, second_directory} = Publication.temporary_directory(root)

    assert first_file != second_file
    assert first_directory != second_directory
    assert File.regular?(first_file)
    assert File.regular?(second_file)
    assert File.dir?(first_directory)
    assert File.dir?(second_directory)
  end

  test "requires an existing directory", %{root: root} do
    file = Path.join(root, "file")
    File.write!(file, "contents")

    assert {:error, :enotdir} = Publication.temporary_file(file)
    assert {:error, :enotdir} = Publication.temporary_directory(file)
    assert {:error, :enoent} = Publication.temporary_file(Path.join(root, "missing"))
  end
end
