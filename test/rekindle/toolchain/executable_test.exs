defmodule Rekindle.Toolchain.ExecutableTest do
  use ExUnit.Case, async: true

  alias Rekindle.Toolchain.Executable

  test "qualifies and executes one unchanged no-follow identity" do
    root = temp_root()
    executable = script!(root, "tool", "printf 'trusted:%s' \"$1\"\n")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, authority} = Executable.qualify(executable)
    assert authority.path == executable
    assert authority.mode == 0o700
    assert authority.sha256 =~ ~r/\A[0-9a-f]{64}\z/
    assert is_integer(authority.identity.major_device)
    assert is_integer(authority.identity.minor_device)
    assert :ok = Executable.revalidate(authority)
    assert {:ok, {"trusted:value", 0}} = Executable.run(authority, ["value"])

    changed_device = put_in(authority.identity.major_device, authority.identity.major_device + 1)
    assert {:error, :executable_changed} = Executable.revalidate(changed_device)
  end

  test "rejects final and ancestor symlinks and nonregular or unsafe modes" do
    root = temp_root()
    executable = script!(root, "real", "exit 0\n")
    link = Path.join(root, "link")
    File.ln_s!(executable, link)

    ancestor = root <> "-link"
    File.ln_s!(root, ancestor)

    no_exec = Path.join(root, "no-exec")
    File.write!(no_exec, "bytes")
    File.chmod!(no_exec, 0o600)

    writable = script!(root, "writable", "exit 0\n")
    File.chmod!(writable, 0o722)

    on_exit(fn ->
      File.rm(ancestor)
      File.rm_rf!(root)
    end)

    assert {:error, _} = Executable.qualify(link)
    assert {:error, _} = Executable.qualify(Path.join(ancestor, "real"))
    assert {:error, _} = Executable.qualify(root)
    assert {:error, _} = Executable.qualify(no_exec)
    assert {:error, _} = Executable.qualify(writable)
  end

  test "detects content and inode changes after admission" do
    root = temp_root()
    executable = script!(root, "tool", "printf original\n")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, content_authority} = Executable.qualify(executable)
    File.write!(executable, "#!/bin/sh\nprintf changed!\n")
    File.chmod!(executable, 0o700)
    assert {:error, :executable_changed} = Executable.revalidate(content_authority)

    assert {:ok, inode_authority} = Executable.qualify(executable)
    replacement = script!(root, "replacement", "printf changed!\n")
    File.rename!(replacement, executable)
    assert {:error, :executable_changed} = Executable.revalidate(inode_authority)
  end

  test "rejects replacement between qualification and spawn" do
    root = temp_root()
    marker = Path.join(root, "ran")
    executable = script!(root, "tool", "printf trusted > #{marker}\n")
    replacement = script!(root, "replacement", "printf replaced > #{marker}\n")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, authority} = Executable.qualify(executable)

    hook = fn ->
      File.rename!(replacement, executable)
      :ok
    end

    assert {:error, :executable_changed} =
             Executable.run(authority, [], before_spawn: hook)

    refute File.exists?(marker)
  end

  test "rejects path replacement immediately after spawn" do
    root = temp_root()
    executable = script!(root, "tool", "sleep 1\n")
    replacement = script!(root, "replacement", "exit 0\n")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, authority} = Executable.qualify(executable)

    hook = fn ->
      File.rename!(replacement, executable)
      :ok
    end

    assert {:error, :executable_changed} =
             Executable.run(authority, [], after_spawn: hook)
  end

  test "creates a private directory without traversing symlink ancestors" do
    root = temp_root()
    private = Path.join([root, "cache", "version", "digest"])
    on_exit(fn -> File.rm_rf!(root) end)

    assert :ok = Executable.ensure_private_directory(private)
    assert Bitwise.band(File.stat!(private).mode, 0o777) == 0o700

    real = Path.join(root, "real")
    File.mkdir!(real)
    linked = Path.join(root, "linked")
    File.ln_s!(real, linked)

    assert {:error, :directory_unqualified} =
             Executable.ensure_private_directory(Path.join(linked, "child"))
  end

  defp script!(root, name, body) do
    path = Path.join(root, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o700)
    path
  end

  defp temp_root do
    path =
      Path.join(System.tmp_dir!(), "rekindle-executable-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    path
  end
end
