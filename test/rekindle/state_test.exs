defmodule Rekindle.StateTest do
  use ExUnit.Case, async: true

  alias Rekindle.State

  test "creates real project state directories component by component" do
    root = temporary_root()
    path = Path.join([root, ".rekindle", "tmp", "web"])

    assert :ok = State.ensure_directory(root, path)
    assert :ok = State.validate_directory(root, path)

    for component <- [
          Path.join(root, ".rekindle"),
          Path.join([root, ".rekindle", "tmp"]),
          path
        ] do
      assert {:ok, %{type: :directory}} = File.lstat(component)
    end
  end

  test "rejects linked and special state ancestors without touching their targets" do
    root = temporary_root()
    external = temporary_root()
    sentinel = Path.join(external, "sentinel")
    File.write!(sentinel, "unchanged")
    File.ln_s!(external, Path.join(root, ".rekindle"))

    path = Path.join([root, ".rekindle", "tmp", "web"])

    assert {:error, {:unsafe_state_path, _, :symlink}} =
             State.ensure_directory(root, path)

    refute File.exists?(Path.join(external, "tmp"))
    assert File.read!(sentinel) == "unchanged"

    File.rm!(Path.join(root, ".rekindle"))
    File.write!(Path.join(root, ".rekindle"), "not a directory")

    assert {:error, {:unsafe_state_path, _, :regular}} =
             State.ensure_directory(root, path)
  end

  test "rejects an intermediate link and leaves external members unchanged" do
    root = temporary_root()
    external = temporary_root()
    state = Path.join(root, ".rekindle")
    File.mkdir!(state)
    File.ln_s!(external, Path.join(state, "dev"))
    sentinel = Path.join(external, "sentinel")
    File.write!(sentinel, "unchanged")

    assert {:error, {:unsafe_state_path, _, :symlink}} =
             State.ensure_directory(root, Path.join([state, "dev", "web"]))

    assert File.read!(sentinel) == "unchanged"
    refute File.exists?(Path.join(external, "web"))
  end

  test "removes only real members beneath validated state ancestry" do
    root = temporary_root()
    directory = Path.join([root, ".rekindle", "tmp", "web"])
    file = Path.join([root, ".rekindle", "dev", "marker.json"])
    assert :ok = State.ensure_directory(root, directory)
    assert :ok = State.ensure_directory(root, Path.dirname(file))
    File.write!(Path.join(directory, "partial"), "partial")
    File.write!(file, "{}")

    assert :ok = State.remove_directory(root, directory)
    assert :ok = State.remove_file(root, file)
    refute File.exists?(directory)
    refute File.exists?(file)
  end

  test "refuses removal through a linked state ancestor" do
    root = temporary_root()
    external = temporary_root()
    victim = Path.join(external, "victim")
    File.mkdir!(victim)
    File.write!(Path.join(victim, "sentinel"), "unchanged")
    File.ln_s!(external, Path.join(root, ".rekindle"))

    assert {:error, {:unsafe_state_path, _, :symlink}} =
             State.remove_directory(root, Path.join([root, ".rekindle", "victim"]))

    assert File.read!(Path.join(victim, "sentinel")) == "unchanged"
  end

  test "rejects paths outside the project state directory" do
    root = temporary_root()

    assert {:error, {:outside_state, _path}} =
             State.ensure_directory(root, Path.join(root, "dist"))
  end

  defp temporary_root do
    path =
      Path.join(
        System.tmp_dir!(),
        "rekindle-state-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
