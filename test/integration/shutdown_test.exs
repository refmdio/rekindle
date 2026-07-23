defmodule Rekindle.ShutdownIntegrationTest do
  use ExUnit.Case, async: true

  alias Rekindle.{EventBus, ProcessRunner, Shutdown}
  alias Rekindle.Shutdown.Result

  @build_key String.duplicate("b", 64)

  defmodule Adapter do
    @behaviour Rekindle.ProcessRunner.Adapter

    @impl true
    def run_exec(_helper, _spawn, _state, options) do
      test = Keyword.fetch!(options, :test_pid)
      :ok = Keyword.fetch!(options, :after_handshake).(self())
      send(test, {:process_started, self()})

      receive do
        {:cancel, header} ->
          send(test, {:process_cancelled, header})

          receive do
            :cleanup_finished ->
              {:ok,
               %{
                 outcome: :signaled,
                 code: nil,
                 signal: 15,
                 cleanup: :confirmed,
                 discarded_stdout: 0,
                 discarded_stderr: 0
               }, "", ""}
          end
      end
    end

    @impl true
    def cancel(worker, header) do
      send(worker, {:cancel, header})
      :ok
    end
  end

  test "shutdown drains owned processes, removes staging, and emits its terminal event" do
    event_bus =
      start_supervised!(
        {EventBus,
         otp_app: :rekindle_shutdown_integration,
         project_session: "0123456789abcdef0123456789abcdef"}
      )

    assert {:ok, subscription} = EventBus.subscribe(event_bus)

    runner =
      start_supervised!({ProcessRunner, adapter: {Adapter, test_pid: self()}})

    coordinator =
      start_supervised!(
        {Shutdown, event_bus: event_bus, process_runners: [runner], timeout_ms: 2_000}
      )

    staging =
      Path.join(
        System.tmp_dir!(),
        "rekindle-shutdown-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(staging)
    File.write!(Path.join(staging, "partial"), "incomplete")
    on_exit(fn -> File.rm_rf(staging) end)

    assert {:ok, _resource} =
             Shutdown.track(coordinator, :staging, cleanup: fn -> remove(staging) end)

    assert {:ok, job} = ProcessRunner.run(runner, request())
    assert_receive {:process_started, worker}

    shutdown = Task.async(fn -> Shutdown.shutdown(coordinator) end)

    assert_receive {:rekindle, ^subscription, {:event, %{type: :session_stopping}}}
    assert_receive {:rekindle, ^subscription, {:closed, :session_stopped}}
    assert_receive {:process_cancelled, %{"reason" => "shutdown"}}
    assert {:error, %{code: :cancelled}} = ProcessRunner.run(runner, request())

    send(worker, :cleanup_finished)

    assert_receive {:rekindle_process, ^job, {:error, %{code: :cancelled}}}
    assert %Result{status: :clean, failures: []} = Task.await(shutdown)
    refute File.exists?(staging)
  end

  defp remove(path) do
    case File.rm_rf(path) do
      {:ok, _paths} -> :ok
      {:error, _reason, _path} -> {:error, cleanup_failure()}
    end
  end

  defp cleanup_failure do
    Rekindle.Failure.new!(
      target: nil,
      stage: :execution,
      code: :cleanup_unconfirmed,
      message: "Staging cleanup was not confirmed"
    )
  end

  defp request do
    [
      target: :web,
      build_key: @build_key,
      helper: "/tmp/rekindle_toolchain",
      executable: "/bin/example",
      argv: [],
      cwd: "/tmp",
      env_mode: :inherit,
      env_set: [],
      env_unset: [],
      terminate_grace_ms: 100,
      kill_grace_ms: 100,
      output_bytes_per_stream: 1_048_576,
      build_timeout_ms: 5_000,
      cleanup_timeout_ms: 500
    ]
  end
end
