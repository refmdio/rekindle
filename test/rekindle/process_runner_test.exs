defmodule Rekindle.ProcessRunnerTest do
  use ExUnit.Case, async: true

  alias Rekindle.ProcessRunner

  @build_key String.duplicate("a", 64)

  defmodule FakeAdapter do
    @behaviour Rekindle.ProcessRunner.Adapter

    @impl true
    def run_exec(_helper, spawn, state, options) do
      test = Keyword.fetch!(options, :test_pid)
      :ok = Keyword.fetch!(options, :after_handshake).(self())
      send(test, {:fake_spawn, self(), spawn, state, options})

      receive do
        {:finish, result, stdout, stderr} ->
          {:ok, result, stdout, stderr}

        {:error, reason} ->
          {:error, reason}

        {:cancel, header} ->
          send(test, {:fake_cancel, header})

          cancelled_result()

        {:cancel, header, cancel_worker} ->
          send(test, {:fake_cancel, header, cancel_worker})

          cancelled_result()

        :crash ->
          raise "adapter crash"
      end
    end

    defp cancelled_result do
      case (receive do
              :finish_cancel -> :ok
              {:error, reason} -> {:error, reason}
            end) do
        :ok ->
          {:ok,
           %{
             outcome: :signaled,
             code: nil,
             signal: 15,
             cleanup: :confirmed,
             discarded_stdout: 0,
             discarded_stderr: 0
           }, "", ""}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def cancel(worker, header) when is_pid(worker) do
      send(worker, {:cancel, header})
      :ok
    end
  end

  defmodule BlockingCancelAdapter do
    @behaviour Rekindle.ProcessRunner.Adapter

    @impl true
    def run_exec(helper, spawn, state, options),
      do: FakeAdapter.run_exec(helper, spawn, state, options)

    @impl true
    def cancel(worker, header) do
      send(worker, {:cancel, header, self()})
      Process.sleep(:infinity)
    end
  end

  setup do
    start_supervised!({ProcessRunner, adapter: {FakeAdapter, test_pid: self()}})
    |> then(&%{runner: &1})
  end

  test "preserves exact argv and environment without a shell", %{runner: runner} do
    assert {:ok, reference} = ProcessRunner.run(runner, request())
    assert_receive {:fake_spawn, worker, spawn, _state, options}

    assert spawn["executable"] == %{"kind" => "path", "value" => "/bin/example tool"}
    assert spawn["argv"] == ["a b", "$(not-executed)", "'quoted'"]
    assert spawn["env_mode"] == "replace"
    assert spawn["env_set"] == [["A", "one"], ["SECRET", "private"]]
    assert Keyword.fetch!(options, :cleanup_timeout_ms) == 500

    send(worker, {:finish, terminal(), "raw stdout", "raw stderr"})
    assert_receive {:rekindle_process, ^reference, {:ok, result}}
    assert result.stdout == "raw stdout"
    assert result.stderr == "raw stderr"
    assert result.execution.outcome == :exited
    assert result.execution.exit_code == 0
    assert result.execution.cleanup == :confirmed
  end

  test "cancellation is idempotent and reports semantic cancellation", %{runner: runner} do
    assert {:ok, reference} = ProcessRunner.run(runner, request())
    assert_receive {:fake_spawn, worker, _spawn, _state, _options}
    assert :ok = ProcessRunner.cancel(runner, reference, :obsolete)
    assert :ok = ProcessRunner.cancel(runner, reference, :obsolete)
    assert_receive {:fake_cancel, %{"type" => "cancel", "reason" => "obsolete"}}
    refute_receive {:fake_cancel, _}, 20
    send(worker, :finish_cancel)
    assert_receive {:rekindle_process, ^reference, {:error, %{code: :cancelled}}}
  end

  test "obsolete cancellation forcibly settles an unresponsive adapter", %{runner: runner} do
    assert {:ok, reference} = ProcessRunner.run(runner, short_cleanup_request())
    assert_receive {:fake_spawn, worker, _spawn, _state, _options}
    worker_monitor = Process.monitor(worker)

    assert :ok = ProcessRunner.cancel(runner, reference, :obsolete)
    assert_receive {:fake_cancel, %{"reason" => "obsolete"}}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500

    assert_receive {:rekindle_process, ^reference, {:error, %{code: :cleanup_unconfirmed}}}

    send(runner, {:runner_cleanup_timeout, reference})
    send(runner, {:runner_result, reference, {:ok, terminal(), "", ""}})
    refute_receive {:rekindle_process, ^reference, _result}, 50
  end

  test "a blocked cancel callback cannot block the cleanup deadline" do
    runner =
      start_supervised!(
        {ProcessRunner, adapter: {BlockingCancelAdapter, test_pid: self()}},
        id: make_ref()
      )

    assert {:ok, reference} = ProcessRunner.run(runner, short_cleanup_request())
    assert_receive {:fake_spawn, worker, _spawn, _state, _options}
    worker_monitor = Process.monitor(worker)

    assert :ok = ProcessRunner.cancel(runner, reference, :obsolete)
    assert_receive {:fake_cancel, %{"reason" => "obsolete"}, cancel_worker}
    cancel_monitor = Process.monitor(cancel_worker)

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500
    assert_receive {:DOWN, ^cancel_monitor, :process, ^cancel_worker, :killed}, 500
    assert_receive {:rekindle_process, ^reference, {:error, %{code: :cleanup_unconfirmed}}}
    assert Process.alive?(runner)
  end

  test "caller cancellation forcibly settles an unresponsive adapter", %{runner: runner} do
    assert {:ok, reference} = ProcessRunner.run(runner, short_cleanup_request())
    assert_receive {:fake_spawn, worker, _spawn, _state, _options}
    worker_monitor = Process.monitor(worker)

    assert :ok = ProcessRunner.cancel(runner, reference, :caller)
    assert_receive {:fake_cancel, %{"reason" => "caller"}}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500

    assert_receive {:rekindle_process, ^reference, {:error, %{code: :cleanup_unconfirmed}}}
  end

  test "uncertain cleanup takes precedence over cancellation", %{runner: runner} do
    assert {:ok, reference} = ProcessRunner.run(runner, request())
    assert_receive {:fake_spawn, worker, _spawn, _state, _options}
    send(worker, {:finish, %{terminal() | cleanup: :uncertain}, "", ""})
    assert_receive {:rekindle_process, ^reference, {:error, %{code: :cleanup_unconfirmed}}}
  end

  test "worker failure is classified without crashing the runner", %{runner: runner} do
    assert {:ok, reference} = ProcessRunner.run(runner, request())
    assert_receive {:fake_spawn, worker, _spawn, _state, _options}
    send(worker, :crash)
    assert_receive {:rekindle_process, ^reference, {:error, %{code: :io_failed}}}
    assert Process.alive?(runner)
  end

  test "semantic timeout sends one timeout intent and waits for cleanup", %{runner: runner} do
    timed = request() |> Keyword.put(:build_timeout_ms, 1_000)
    assert {:ok, reference} = ProcessRunner.run(runner, timed)
    assert_receive {:fake_spawn, worker, _spawn, _state, _options}
    assert_receive {:fake_cancel, %{"reason" => "timeout"}}, 1_500
    send(worker, :finish_cancel)
    assert_receive {:rekindle_process, ^reference, {:error, %{code: :build_timeout}}}
  end

  test "build timeout forcibly settles an unresponsive adapter", %{runner: runner} do
    timed =
      short_cleanup_request()
      |> Keyword.put(:build_timeout_ms, 1_000)

    assert {:ok, reference} = ProcessRunner.run(runner, timed)
    assert_receive {:fake_spawn, worker, _spawn, _state, _options}
    worker_monitor = Process.monitor(worker)
    assert_receive {:fake_cancel, %{"reason" => "timeout"}}, 1_500
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500

    assert_receive {:rekindle_process, ^reference, {:error, %{code: :cleanup_unconfirmed}}}
  end

  test "owner death forcibly settles an unresponsive adapter", %{runner: runner} do
    test = self()

    owner =
      spawn(fn ->
        {:ok, reference} = ProcessRunner.run(runner, short_cleanup_request())
        send(test, {:owner_job, self(), reference})
        Process.sleep(:infinity)
      end)

    assert_receive {:owner_job, ^owner, _reference}
    assert_receive {:fake_spawn, worker, _spawn, _state, _options}
    worker_monitor = Process.monitor(worker)
    Process.exit(owner, :kill)

    assert_receive {:fake_cancel, %{"reason" => "caller"}}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500
    assert eventually_jobs_empty?(runner)
  end

  test "helper errors use compatibility and execution failure taxonomy", %{runner: runner} do
    assert {:ok, missing} = ProcessRunner.run(runner, request())
    assert_receive {:fake_spawn, worker, _spawn, _state, _options}
    send(worker, {:error, :helper_missing})
    assert_receive {:rekindle_process, ^missing, {:error, %{code: :helper_missing}}}

    assert {:ok, broken} = ProcessRunner.run(runner, request())
    assert_receive {:fake_spawn, worker, _spawn, _state, _options}
    send(worker, {:error, :helper_protocol})
    assert_receive {:rekindle_process, ^broken, {:error, %{code: :io_failed}}}
  end

  test "only the submitting caller can cancel a job", %{runner: runner} do
    assert {:ok, reference} = ProcessRunner.run(runner, request())
    assert_receive {:fake_spawn, worker, _spawn, _state, _options}

    task = Task.async(fn -> ProcessRunner.cancel(runner, reference, :caller) end)
    assert {:error, %{code: :cancelled}} = Task.await(task)
    send(worker, {:finish, terminal(), "", ""})
    assert_receive {:rekindle_process, ^reference, {:ok, _result}}
  end

  test "public tails are redacted while bounded internal bytes remain exact", %{runner: runner} do
    previous = Application.get_env(:rekindle, :redact_values)
    Application.put_env(:rekindle, :redact_values, ["private"])

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:rekindle, :redact_values),
        else: Application.put_env(:rekindle, :redact_values, previous)
    end)

    assert {:ok, reference} = ProcessRunner.run(runner, request())
    assert_receive {:fake_spawn, worker, _spawn, _state, _options}
    send(worker, {:finish, terminal(), "private-json", <<255, 0, 1>>})
    assert_receive {:rekindle_process, ^reference, {:ok, result}}
    assert result.stdout == "private-json"
    assert result.stderr == <<255, 0, 1>>
    assert result.execution.stdout_tail == "<redacted>-json"
    refute result.execution.stderr_tail == result.stderr
  end

  test "shutdown rejects admission, cancels every job, and is idempotent", %{runner: runner} do
    assert {:ok, first} = ProcessRunner.run(runner, request())
    assert_receive {:fake_spawn, first_worker, _spawn, _state, _options}
    assert {:ok, second} = ProcessRunner.run(runner, request())
    assert_receive {:fake_spawn, second_worker, _spawn, _state, _options}

    assert {:ok, shutdown} = ProcessRunner.begin_shutdown(runner)
    assert is_reference(shutdown)
    assert {:error, %{code: :cancelled}} = ProcessRunner.run(runner, request())

    assert_receive {:fake_cancel, %{"reason" => "shutdown"}}
    assert_receive {:fake_cancel, %{"reason" => "shutdown"}}
    send(first_worker, :finish_cancel)
    send(second_worker, :finish_cancel)

    assert_receive {:rekindle_process, ^first, {:error, %{code: :cancelled}}}
    assert_receive {:rekindle_process, ^second, {:error, %{code: :cancelled}}}
    assert_receive {:rekindle_process_runner_shutdown, ^shutdown, :ok}
    assert {:ok, :stopped} = ProcessRunner.begin_shutdown(runner)
  end

  test "shutdown reports cleanup that cannot be confirmed", %{runner: runner} do
    assert {:ok, job} = ProcessRunner.run(runner, request())
    assert_receive {:fake_spawn, worker, _spawn, _state, _options}
    assert {:ok, shutdown} = ProcessRunner.begin_shutdown(runner)
    assert_receive {:fake_cancel, %{"reason" => "shutdown"}}
    send(worker, {:error, :helper_protocol})

    assert_receive {:rekindle_process, ^job, {:error, %{code: :cleanup_unconfirmed}}}

    assert_receive {:rekindle_process_runner_shutdown, ^shutdown,
                    {:error, [%{code: :cleanup_unconfirmed}]}}
  end

  test "shutdown deadline settles hung jobs and wakes its waiter", %{runner: runner} do
    assert {:ok, job} = ProcessRunner.run(runner, short_cleanup_request())
    assert_receive {:fake_spawn, worker, _spawn, _state, _options}
    worker_monitor = Process.monitor(worker)
    assert {:ok, shutdown} = ProcessRunner.begin_shutdown(runner)
    assert_receive {:fake_cancel, %{"reason" => "shutdown"}}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500

    assert_receive {:rekindle_process, ^job, {:error, %{code: :cleanup_unconfirmed}}}

    assert_receive {:rekindle_process_runner_shutdown, ^shutdown,
                    {:error, [%{code: :cleanup_unconfirmed}]}}

    assert {:ok, :stopped} = ProcessRunner.begin_shutdown(runner)
  end

  test "completion cancels the cleanup deadline and remains the only result", %{runner: runner} do
    assert {:ok, reference} = ProcessRunner.run(runner, short_cleanup_request())
    assert_receive {:fake_spawn, worker, _spawn, _state, _options}
    assert :ok = ProcessRunner.cancel(runner, reference, :obsolete)
    assert_receive {:fake_cancel, %{"reason" => "obsolete"}}
    send(worker, :finish_cancel)

    assert_receive {:rekindle_process, ^reference, {:error, %{code: :cancelled}}}
    refute_receive {:rekindle_process, ^reference, _result}, 200
    assert Process.alive?(runner)
  end

  defp request do
    [
      target: :web,
      build_key: @build_key,
      helper: "/tmp/rekindle_toolchain",
      executable: "/bin/example tool",
      argv: ["a b", "$(not-executed)", "'quoted'"],
      cwd: "/tmp",
      env_mode: :replace,
      env_set: [{"SECRET", "private"}, {"A", "one"}],
      env_unset: ["OLD"],
      terminate_grace_ms: 100,
      kill_grace_ms: 100,
      output_bytes_per_stream: 1_048_576,
      build_timeout_ms: 5_000,
      cleanup_timeout_ms: 500
    ]
  end

  defp short_cleanup_request,
    do: Keyword.put(request(), :cleanup_timeout_ms, 100)

  defp eventually_jobs_empty?(runner, attempts \\ 20)

  defp eventually_jobs_empty?(runner, attempts) when attempts > 0 do
    if map_size(:sys.get_state(runner).jobs) == 0 do
      true
    else
      Process.sleep(20)
      eventually_jobs_empty?(runner, attempts - 1)
    end
  end

  defp eventually_jobs_empty?(_runner, 0), do: false

  defp terminal do
    %{
      outcome: :exited,
      code: 0,
      signal: nil,
      cleanup: :confirmed,
      discarded_stdout: 0,
      discarded_stderr: 0
    }
  end
end
