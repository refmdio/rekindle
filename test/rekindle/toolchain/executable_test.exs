defmodule Rekindle.Toolchain.ExecutableTest do
  use ExUnit.Case, async: false

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

  test "executes the admitted handle across an ABA pathname swap during spawn" do
    root = temp_root()
    executable = script!(root, "tool", "printf trusted\n")
    replacement = script!(root, "replacement", "printf malicious\n")
    admitted_path = executable <> ".admitted"
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, authority} = Executable.qualify(executable)

    around_spawn = fn _authority, launch_path, spawn ->
      assert String.contains?(launch_path, ["/proc/", "/dev/fd/"])
      File.rename!(executable, admitted_path)
      File.rename!(replacement, executable)

      try do
        spawn.()
      after
        File.rename!(executable, replacement)
        File.rename!(admitted_path, executable)
      end
    end

    assert {:ok, {"trusted", 0}} =
             Executable.run(authority, [], around_spawn: around_spawn)
  end

  test "executes immutable admitted bytes across a same-inode content ABA during spawn" do
    root = temp_root()
    trusted_marker = Path.join(root, "trusted-ran")
    malicious_marker = Path.join(root, "malicious-ran")
    executable = Path.join(root, "tool")

    trusted =
      padded_script(
        "printf started > #{trusted_marker}\nprintf trusted\n",
        512
      )

    malicious =
      padded_script(
        "printf started > #{malicious_marker}\nprintf hostile\n",
        512
      )

    assert byte_size(trusted) == byte_size(malicious)
    File.write!(executable, trusted)
    File.chmod!(executable, 0o700)
    original_inode = File.stat!(executable).inode
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, authority} = Executable.qualify(executable)

    around_spawn = fn _authority, launch_path, spawn ->
      assert String.contains?(launch_path, ["/proc/", "/dev/fd/"])
      File.write!(executable, malicious)
      assert File.stat!(executable).inode == original_inode

      result = spawn.()

      assert wait_file(trusted_marker, 1_000)
      refute File.exists?(malicious_marker)
      File.write!(executable, trusted)
      assert File.stat!(executable).inode == original_inode
      result
    end

    assert {:ok, {"trusted", 0}} =
             Executable.run(authority, [], around_spawn: around_spawn)

    refute File.exists?(malicious_marker)
    assert File.stat!(executable).inode == original_inode
  end

  test "rejects path replacement immediately after spawn" do
    root = temp_root()
    pid_file = Path.join(root, "pid")
    executable = script!(root, "tool", "echo $$ > #{pid_file}\n")
    replacement = script!(root, "replacement", "exit 0\n")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, authority} = Executable.qualify(executable)

    around_spawn = fn _authority, _launch_path, spawn ->
      result = spawn.()
      assert wait_file(pid_file, 1_000)
      result
    end

    hook = fn ->
      File.rename!(replacement, executable)
      :ok
    end

    assert {:error, :executable_changed} =
             Executable.run(authority, [], around_spawn: around_spawn, after_spawn: hook)

    pid = pid_file |> File.read!() |> String.trim() |> String.to_integer()
    assert wait_process_absent(pid, 1_000)
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

  test "settles every unique launch root, descriptor and port on success and failure" do
    root = temp_root()
    executable = script!(root, "tool", "exit 0\n")
    sleeper = script!(root, "sleeper", "sleep 30\n")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, authority} = Executable.qualify(executable)
    assert {:ok, sleep_authority} = Executable.qualify(sleeper)

    roots = launch_roots()
    ports = MapSet.new(Port.list())
    descriptors = descriptor_count()

    for iteration <- 1..25 do
      assert {:ok, {"", 0}} = Executable.run(authority, [])
      assert roots == launch_roots(), "success roots iteration #{iteration}"
      assert ports == MapSet.new(Port.list()), "success ports iteration #{iteration}"
      assert descriptors == descriptor_count(), "success descriptors iteration #{iteration}"
    end

    assert {:error, :executable_changed} =
             Executable.run(authority, [],
               around_spawn: fn _authority, _path, _spawn ->
                 {:error, :forced}
               end
             )

    assert roots == launch_roots()
    assert ports == MapSet.new(Port.list())
    assert descriptors == descriptor_count()

    assert {:error, :executable_changed} =
             Executable.run(authority, [], after_spawn: fn -> {:error, :forced} end)

    assert roots == launch_roots()
    assert ports == MapSet.new(Port.list())
    assert descriptors == descriptor_count()

    assert {:error, :executable_timeout} =
             Executable.run(sleep_authority, [], timeout_ms: 25)

    assert roots == launch_roots()
    assert ports == MapSet.new(Port.list())
    assert descriptors == descriptor_count()
  end

  test "preserves a foreign entry instead of removing a changed launch root" do
    root = temp_root()
    executable = script!(root, "tool", "exit 0\n")
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, authority} = Executable.qualify(executable)
    parent = self()

    around_spawn = fn _authority, launch_path, spawn ->
      sealed_path = launch_path |> File.read_link!() |> String.replace_suffix(" (deleted)", "")
      launch_root = Path.dirname(sealed_path)
      foreign = Path.join(launch_root, "foreign")
      File.write!(foreign, "preserve")
      send(parent, {:foreign_launch_root, launch_root, foreign})
      spawn.()
    end

    assert {:ok, {"", 0}} = Executable.run(authority, [], around_spawn: around_spawn)
    assert_receive {:foreign_launch_root, launch_root, foreign}
    assert File.read!(foreign) == "preserve"
    assert {:ok, %{type: :directory}} = File.lstat(launch_root)
    assert Bitwise.band(File.stat!(launch_root).mode, 0o777) == 0o700
    File.rm_rf!(launch_root)
  end

  defp script!(root, name, body) do
    path = Path.join(root, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o700)
    path
  end

  defp padded_script(body, size) do
    prefix = "#!/bin/sh\n" <> body <> "#"
    true = byte_size(prefix) <= size
    prefix <> String.duplicate("x", size - byte_size(prefix))
  end

  defp temp_root do
    path =
      Path.join(System.tmp_dir!(), "rekindle-executable-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp launch_roots do
    System.tmp_dir!()
    |> Path.join(".rekindle-launch-*")
    |> Path.wildcard()
    |> MapSet.new()
  end

  defp descriptor_count do
    ["/proc/self/fd", "/dev/fd"]
    |> Enum.find_value(fn path ->
      case File.ls(path) do
        {:ok, entries} -> length(entries)
        _ -> nil
      end
    end)
    |> case do
      nil -> raise "an observable process descriptor directory is required"
      count -> count
    end
  end

  defp wait_file(path, timeout) do
    wait_until(timeout, fn -> File.regular?(path) end)
  end

  defp wait_process_absent(pid, timeout) do
    wait_until(timeout, fn -> not File.exists?("/proc/#{pid}") end)
  end

  defp wait_until(timeout, predicate) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(deadline, predicate)
  end

  defp do_wait_until(deadline, predicate) do
    cond do
      predicate.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        do_wait_until(deadline, predicate)
    end
  end
end
