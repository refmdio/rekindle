defmodule Rekindle.ProcessRunnerIntegrationTest do
  use ExUnit.Case, async: false

  alias Rekindle.ProcessRunner

  @build_key String.duplicate("c", 64)

  setup_all do
    target = Path.expand("_build/test/rekindle-toolchain")
    cargo = System.find_executable("cargo") || raise "cargo is required"

    assert {_output, 0} =
             System.cmd(
               cargo,
               [
                 "build",
                 "--release",
                 "--locked",
                 "--manifest-path",
                 Path.expand("crates/rekindle-toolchain/Cargo.toml")
               ],
               env: [{"CARGO_TARGET_DIR", target}],
               stderr_to_stdout: true
             )

    helper = Path.join(target, "release/rekindle_toolchain")
    assert File.regular?(helper)
    %{helper: helper}
  end

  setup do
    root = temp_root()
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, runner: start_supervised!({ProcessRunner, []}, id: make_ref())}
  end

  test "executes exact arguments and a replacement environment without shell expansion",
       context do
    executable = Path.join(context.root, "argument printer")
    marker = Path.join(context.root, "must-not-exist")
    secret = "runner-private-value"

    File.write!(
      executable,
      "#!/bin/sh\nprintf '%s\\n' \"$#\"\nfor value do printf '[%s]\\n' \"$value\"; done\nprintf '%s' \"$TOKEN\" >&2\n"
    )

    File.chmod!(executable, 0o700)

    assert {:ok, reference} =
             ProcessRunner.run(
               context.runner,
               request(context,
                 executable: executable,
                 argv: ["a b", "$(touch #{marker})", "'quoted'"],
                 env_set: [{"TOKEN", secret}],
                 redact_values: [secret]
               )
             )

    assert_receive {:rekindle_process, ^reference, {:ok, result}}, 5_000

    assert result.stdout == "3\n[a b]\n[$(touch #{marker})]\n['quoted']\n"
    assert result.stderr == "<redacted>"
    assert result.execution.stderr_tail == "<redacted>"
    assert result.execution.outcome == :exited
    assert result.execution.exit_code == 0
    assert result.execution.cleanup == :confirmed
    refute File.exists?(marker)
  end

  test "bounds binary output and reports discarded bytes", context do
    executable = System.find_executable("head") |> Path.expand()

    assert {:ok, reference} =
             ProcessRunner.run(
               context.runner,
               request(context,
                 executable: executable,
                 argv: ["-c", "1100000", "/dev/zero"]
               )
             )

    assert_receive {:rekindle_process, ^reference, {:ok, result}}, 5_000
    assert byte_size(result.stdout) == 1_048_576
    assert result.stdout == :binary.copy(<<0>>, 1_048_576)
    assert result.execution.discarded_bytes.stdout == 51_424
    assert result.execution.stdout_tail == "<redacted>"
  end

  test "timeout terminates and reaps the descendant group", context do
    {executable, descendant_file} = descendant_script(context.root, "timeout")

    assert {:ok, reference} =
             ProcessRunner.run(
               context.runner,
               request(context,
                 executable: executable,
                 build_timeout_ms: 1_000
               )
             )

    assert wait_file(descendant_file, 1_000)
    descendant = read_pid(descendant_file)

    assert_receive {:rekindle_process, ^reference, {:error, %{code: :build_timeout}}}, 4_000
    assert wait_process_absent(descendant, 2_000)
    assert :sys.get_state(context.runner).jobs == %{}
  end

  test "shutdown closes admission and reaps every running descendant", context do
    {first_executable, first_file} = descendant_script(context.root, "first")
    {second_executable, second_file} = descendant_script(context.root, "second")

    assert {:ok, first} =
             ProcessRunner.run(context.runner, request(context, executable: first_executable))

    assert {:ok, second} =
             ProcessRunner.run(context.runner, request(context, executable: second_executable))

    assert wait_file(first_file, 1_000)
    assert wait_file(second_file, 1_000)
    first_descendant = read_pid(first_file)
    second_descendant = read_pid(second_file)

    assert {:ok, shutdown} = ProcessRunner.begin_shutdown(context.runner)
    assert is_reference(shutdown)

    assert {:error, %{code: :cancelled}} =
             ProcessRunner.run(context.runner, request(context, executable: first_executable))

    assert_receive {:rekindle_process, ^first, {:error, %{code: :cancelled}}}, 4_000
    assert_receive {:rekindle_process, ^second, {:error, %{code: :cancelled}}}, 4_000
    assert_receive {:rekindle_process_runner_shutdown, ^shutdown, :ok}, 4_000
    assert wait_process_absent(first_descendant, 2_000)
    assert wait_process_absent(second_descendant, 2_000)
    assert {:ok, :stopped} = ProcessRunner.begin_shutdown(context.runner)
  end

  test "reports a real signal with confirmed cleanup", context do
    executable = Path.join(context.root, "signal-self")
    File.write!(executable, "#!/bin/sh\nkill -TERM $$\n")
    File.chmod!(executable, 0o700)

    assert {:ok, reference} =
             ProcessRunner.run(context.runner, request(context, executable: executable))

    assert_receive {:rekindle_process, ^reference, {:ok, result}}, 5_000
    assert result.execution.outcome == :signaled
    assert result.execution.signal == 15
    assert result.execution.exit_code == nil
    assert result.execution.cleanup == :confirmed
  end

  defp request(context, overrides) do
    Keyword.merge(
      [
        target: :web,
        build_key: @build_key,
        helper: context.helper,
        executable: "/usr/bin/true",
        argv: [],
        cwd: context.root,
        env_mode: :replace,
        env_set: [],
        env_unset: [],
        redact_values: [],
        terminate_grace_ms: 100,
        kill_grace_ms: 500,
        output_bytes_per_stream: 1_048_576,
        build_timeout_ms: 5_000,
        cleanup_timeout_ms: 2_000
      ],
      overrides
    )
  end

  defp descendant_script(root, label) do
    executable = Path.join(root, "descendants-#{label}")
    descendant_file = Path.join(root, "descendant-#{label}.pid")

    File.write!(
      executable,
      "#!/bin/sh\n/bin/sleep 30 &\nprintf '%s' $! > '#{descendant_file}'\nwait\n"
    )

    File.chmod!(executable, 0o700)
    {executable, descendant_file}
  end

  defp read_pid(path), do: path |> File.read!() |> String.trim() |> String.to_integer()

  defp wait_file(path, timeout), do: wait_until(timeout, fn -> File.regular?(path) end)

  defp wait_process_absent(pid, timeout),
    do: wait_until(timeout, fn -> not process_exists?(pid) end)

  defp wait_until(timeout, predicate) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_until_deadline(deadline, predicate)
  end

  defp wait_until_deadline(deadline, predicate) do
    cond do
      predicate.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        wait_until_deadline(deadline, predicate)
    end
  end

  defp process_exists?(pid) do
    case File.read("/proc/#{pid}/status") do
      {:ok, status} ->
        not String.contains?(status, "\nState:\tZ")

      _ ->
        match?(
          {_output, 0},
          System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
        )
    end
  end

  defp temp_root do
    Path.join(
      System.tmp_dir!(),
      "rekindle-process-runner-#{System.unique_integer([:positive, :monotonic])}"
    )
  end
end
