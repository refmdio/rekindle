defmodule Rekindle.ToolchainHelperIntegrationTest do
  use ExUnit.Case, async: false

  alias Rekindle.Toolchain.{Exec, Frame, Handshake, Helper, Installer, Release, Web}

  @request "0123456789abcdef0123456789abcdef"

  setup_all do
    cache = temp_root("installed")
    source = Path.expand("crates/rekindle-toolchain")
    on_exit(fn -> File.rm_rf!(cache) end)

    assert {:ok, helper} =
             Release.ensure(true, cache_root: cache, source_root: source, offline: true)

    refute String.contains?(helper, "/target/")
    assert File.regular?(helper)
    assert Bitwise.band(File.stat!(helper).mode, 0o100) != 0
    %{helper: helper}
  end

  test "exec-v1 negotiates, preserves binary streams, and reports a confirmed exit", %{
    helper: helper
  } do
    executable = System.find_executable("printf") |> Path.expand()

    assert {:ok, spawn, state} =
             Exec.spawn_request(
               request_id: @request,
               executable: executable,
               argv: ["%s", "hello world"],
               cwd: System.tmp_dir!(),
               env_mode: :replace,
               terminate_grace_ms: 100,
               kill_grace_ms: 100
             )

    assert {:ok, terminal, "hello world", ""} =
             Helper.run_exec(helper, spawn, state, timeout_ms: 5_000)

    assert terminal.outcome == :exited
    assert terminal.code == 0
    assert terminal.cleanup == :confirmed
    assert terminal.stdout_bytes == 11
  end

  test "exec-v1 timeout terminates and reaps the complete descendant process group", %{
    helper: helper
  } do
    root = temp_root("exec")
    script = Path.join(root, "descendants")

    File.mkdir_p!(root)
    File.write!(script, "#!/bin/sh\nsleep 30 &\necho $!\nwait\n")
    File.chmod!(script, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, spawn, state} =
             Exec.spawn_request(
               request_id: @request,
               executable: script,
               cwd: root,
               terminate_grace_ms: 100,
               kill_grace_ms: 500
             )

    assert {:ok, terminal, stdout, ""} =
             Helper.run_exec(helper, spawn, state,
               timeout_ms: 150,
               cleanup_timeout_ms: 2_000
             )

    descendant = stdout |> String.trim() |> String.to_integer()
    assert terminal.outcome == :signaled
    assert terminal.cleanup == :confirmed
    refute process_exists?(descendant)
  end

  test "guardian removes the descendant group when the helper dies after started", %{
    helper: helper
  } do
    root = temp_root("helper-death")
    script = Path.join(root, "descendants")
    descendant_file = Path.join(root, "descendant.pid")
    File.mkdir_p!(root)
    File.write!(script, "#!/bin/sh\nsleep 30 &\necho $! > #{descendant_file}\nwait\n")
    File.chmod!(script, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, spawn, state} =
             Exec.spawn_request(
               request_id: @request,
               executable: script,
               cwd: root,
               terminate_grace_ms: 100,
               kill_grace_ms: 500
             )

    result =
      Helper.run_exec(helper, spawn, state,
        timeout_ms: 5_000,
        cleanup_timeout_ms: 2_000,
        started_hook: fn port, _state ->
          assert wait_file(descendant_file, 1_000)
          {:os_pid, helper_pid} = Port.info(port, :os_pid)
          {_output, 0} = System.cmd("/usr/bin/kill", ["-KILL", Integer.to_string(helper_pid)])
        end
      )

    assert {:error, _reason} = result
    descendant = descendant_file |> File.read!() |> String.trim() |> String.to_integer()
    assert wait_process_absent(descendant, 2_000)
  end

  test "guardian closes the ownership race before started is admitted", %{
    helper: helper
  } do
    root = temp_root("pre-start")
    script = Path.join(root, "leader")
    leader_file = Path.join(root, "leader.pid")
    File.mkdir_p!(root)
    File.write!(script, "#!/bin/sh\necho $$ > #{leader_file}\nsleep 30\n")
    File.chmod!(script, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    port = open_helper(helper, "exec-v1")
    negotiate(port, "exec-v1")

    assert {:ok, spawn, _state} =
             Exec.spawn_request(
               request_id: @request,
               executable: script,
               cwd: root,
               terminate_grace_ms: 100,
               kill_grace_ms: 500
             )

    assert {:ok, encoded} = Frame.encode(spawn)
    assert Port.command(port, encoded)
    assert wait_file(leader_file, 1_000)
    {:os_pid, helper_pid} = Port.info(port, :os_pid)
    {_output, 0} = System.cmd("/usr/bin/kill", ["-KILL", Integer.to_string(helper_pid)])
    assert_receive {^port, {:exit_status, _status}}, 1_000

    leader = leader_file |> File.read!() |> String.trim() |> String.to_integer()
    assert wait_process_absent(leader, 1_000)
  end

  test "exec-v1 bounds retained binary output and reports discarded bytes", %{helper: helper} do
    executable = System.find_executable("head") |> Path.expand()

    assert {:ok, spawn, state} =
             Exec.spawn_request(
               request_id: @request,
               executable: executable,
               argv: ["-c", "1100000", "/dev/zero"],
               cwd: System.tmp_dir!(),
               terminate_grace_ms: 100,
               kill_grace_ms: 100
             )

    assert {:ok, terminal, stdout, ""} =
             Helper.run_exec(helper, spawn, state, timeout_ms: 5_000)

    assert byte_size(stdout) == 1_048_576
    assert terminal.stdout_bytes == 1_048_576
    assert terminal.discarded_stdout == 51_424
    assert terminal.cleanup == :confirmed
  end

  test "the real helper rejects compatibility mismatch and noncanonical hello", %{
    helper: helper
  } do
    expected = %{Helper.compatibility() | "helper_version" => "9.9.9"}
    host = Installer.host() |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    hello = Handshake.hello("web-v1", expected, host)
    port = open_helper(helper, "web-v1")
    assert {:ok, encoded} = Frame.encode(hello)
    assert Port.command(port, encoded)

    assert {:ok, %{"type" => "hello_error", "code" => "version_mismatch"}, <<>>} =
             receive_frame(port, <<>>)

    assert_receive {^port, {:exit_status, 2}}, 1_000

    port = open_helper(helper, "web-v1")
    request_id = String.duplicate("0", 32)
    noncanonical = ~s({"v":1, "type":"hello","request_id":"#{request_id}","payload_len":0})
    assert Port.command(port, <<byte_size(noncanonical)::32, noncanonical::binary>>)
    assert_receive {^port, {:exit_status, 2}}, 1_000
    refute_receive {^port, {:data, _bytes}}, 50
  end

  test "web-v1 performs bindgen, package, verify, and detects post-package tampering", %{
    helper: helper
  } do
    root = temp_root("web")
    input = Path.join(root, "input")
    bindgen_output = Path.join(root, "bindgen")
    package_output = Path.join(root, "package")
    Enum.each([input, bindgen_output, package_output], &File.mkdir_p!/1)
    File.write!(Path.join(input, "app.wasm"), <<0, 97, 115, 109, 1, 0, 0, 0>>)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, input_root} = Web.root(input, :read, id: id(1))
    assert {:ok, wasm} = Web.file(input_root, "app.wasm")
    assert {:ok, bindgen_root} = Web.prepare_output_root(bindgen_output, id: id(2))
    limits = limits()

    marker = Path.join(bindgen_output, Web.marker())
    File.chmod!(marker, 0o700)

    assert {:ok, rejected_request, rejected_state} =
             bindgen_operation(input_root, wasm, bindgen_root, limits)

    assert {:ok, %{"type" => "operation_error", "code" => "invalid_request"}, []} =
             Helper.run_web(helper, rejected_request, rejected_state)

    File.chmod!(marker, 0o600)

    assert {:ok, request, state} = bindgen_operation(input_root, wasm, bindgen_root, limits)

    assert {:ok, %{"type" => "operation_ok", "op" => "bindgen_web"} = bound, []} =
             Helper.run_web(helper, request, state)

    assert {:ok, bindgen_read} = Web.root(bindgen_output, :read, id: id(3))

    bindgen_files =
      Enum.map(bound["files"], fn descriptor ->
        {:ok, descriptor} = Web.file(bindgen_read, descriptor["path"])
        descriptor
      end)

    assert {:ok, package_root} = Web.prepare_output_root(package_output, id: id(4))

    assert {:ok, request, state} =
             Web.operation(
               "package_web",
               %{
                 bindgen_root: bindgen_read,
                 bindgen_files: bindgen_files,
                 public_root: nil,
                 public_files: [],
                 bootstrap_template: Web.bootstrap_template(),
                 output_root: package_root,
                 manifest_base: manifest_base(),
                 limits: limits
               },
               request_id: @request
             )

    assert {:ok, %{"type" => "operation_ok", "op" => "package_web"} = package, []} =
             Helper.run_web(helper, request, state)

    assert :ok = Web.revalidate_files(package_root, package["files"])
    assert {:ok, artifact_root} = Web.root(package_output, :read, id: id(5))
    assert {:ok, manifest} = Web.file(artifact_root, "rekindle-web-manifest-v1.json")

    assert {:ok, request, state} =
             Web.operation(
               "verify_web",
               %{
                 artifact_root: artifact_root,
                 manifest: manifest,
                 expected_manifest_digest: package["manifest_digest"],
                 limits: limits
               },
               request_id: @request
             )

    assert {:ok, %{"type" => "operation_ok", "op" => "verify_web"} = verified, []} =
             Helper.run_web(helper, request, state)

    assert verified["artifact_id"] == package["artifact_id"]

    member =
      package_output
      |> Path.join("members/**/*")
      |> Path.wildcard()
      |> Enum.find(&File.regular?/1)

    File.write!(member, "tampered")

    assert {:ok, %{"type" => "operation_error", "code" => "input_changed"}, []} =
             Helper.run_web(helper, request, state)
  end

  defp limits do
    {:ok, limits} =
      Web.limits(
        max_files: 100,
        max_input_bytes: 10_000_000,
        max_output_bytes: 10_000_000,
        deadline_ms: 30_000
      )

    limits
  end

  defp bindgen_operation(input_root, wasm, output_root, limits) do
    Web.operation(
      "bindgen_web",
      %{
        input_root: input_root,
        input_wasm: wasm,
        output_root: output_root,
        output_stem: "app",
        debug: false,
        source_maps: :none,
        expected_wasm_bindgen: "0.2.121",
        limits: limits
      },
      request_id: @request
    )
  end

  defp manifest_base do
    %{
      rekindle_version: "0.1.0",
      application_id: "sample_app",
      target: "web",
      build: %{
        build_key: String.duplicate("a", 64),
        profile: "dev",
        package: "sample_app_ui",
        binary: "sample_app-web",
        features: ["web"]
      },
      producer: %{
        kind: "canonical_web",
        rustc: "1.95.0",
        cargo: "1.95.0",
        rust_target: "wasm32-unknown-unknown",
        gpui_revision: String.duplicate("b", 40),
        helper_version: "0.1.0",
        helper_protocol: 1,
        wasm_bindgen: "0.2.121",
        compatibility_tuple_id: "test-linux-x86_64"
      },
      host_requirements: %{secure_context: true, webgpu: true},
      hot_styles: []
    }
  end

  defp id(number), do: number |> Integer.to_string(16) |> String.pad_leading(32, "0")

  defp process_exists?(pid) do
    case File.read("/proc/#{pid}/status") do
      {:ok, status} when is_binary(status) ->
        not String.contains?(status, "\nState:\tZ")

      _ ->
        case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
          {_, 0} -> true
          {_, _} -> false
        end
    end
  end

  defp open_helper(helper, mode) do
    Port.open(
      {:spawn_executable, String.to_charlist(helper)},
      [:binary, :exit_status, :use_stdio, args: [mode]]
    )
  end

  defp receive_frame(port, buffer) do
    case Frame.decode(buffer) do
      {:ok, header, payload, _remaining} ->
        {:ok, header, payload}

      {:more, _} ->
        receive do
          {^port, {:data, bytes}} -> receive_frame(port, buffer <> bytes)
        after
          1_000 -> {:error, :timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp negotiate(port, mode) do
    host = Installer.host() |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    hello = Handshake.hello(mode, Helper.compatibility(), host)
    {:ok, encoded} = Frame.encode(hello)
    true = Port.command(port, encoded)
    {:ok, %{"type" => "hello_ok"}, <<>>} = receive_frame(port, <<>>)
    :ok
  end

  defp wait_file(path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    cond do
      File.regular?(path) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        wait_file(path, deadline - System.monotonic_time(:millisecond))
    end
  end

  defp wait_process_absent(pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    cond do
      not process_exists?(pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        wait_process_absent(pid, deadline - System.monotonic_time(:millisecond))
    end
  end

  defp temp_root(label) do
    Path.join(
      System.tmp_dir!(),
      "rekindle-helper-#{label}-#{System.unique_integer([:positive])}"
    )
  end
end
