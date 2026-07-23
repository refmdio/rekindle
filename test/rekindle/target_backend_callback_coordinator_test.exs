defmodule Rekindle.TargetBackend.CallbackCoordinatorTest do
  use ExUnit.Case, async: false

  alias Rekindle.{BackendContext, ExecutionResult, ExternalArtifact, ExternalPlan, TargetBackend}
  alias Rekindle.TargetBackend.CallbackCoordinator

  defmodule Backend do
    def backend_id, do: run(:backend_id, "coordinator.backend")
    def backend_version, do: run(:backend_version, "1")
    def validate(_target, options), do: run(:validate, {:ok, options})

    def plan(_context, _options) do
      run(
        :plan,
        {:ok,
         %ExternalPlan{
           executable: "/bin/true",
           argv: [],
           cwd: %{root: :staging, path: "."},
           env_mode: :replace,
           env_set: [],
           diagnostic_mode: :opaque,
           timeout_ms: 1_000,
           expected_manifest: "manifest.json"
         }}
      )
    end

    def finalize(_context, _options, _result) do
      run(
        :finalize,
        {:ok, %ExternalArtifact{manifest: "manifest.json", supplemental_diagnostics: []}}
      )
    end

    defp run(callback, default) do
      case :persistent_term.get({__MODULE__, callback}, :return) do
        :return ->
          default

        {:value, value} ->
          value

        :sleep ->
          Process.sleep(:infinity)

        :throw ->
          throw(:callback_throw)

        :exit ->
          exit(:callback_exit)

        :error ->
          raise "callback error"

        :spawn ->
          owner = :persistent_term.get({__MODULE__, :test_owner})

          spawn(fn ->
            send(owner, {:callback_child, self()})
            Process.sleep(:infinity)
          end)

          default

        :spawn_then_error ->
          owner = :persistent_term.get({__MODULE__, :test_owner})

          spawn(fn ->
            send(owner, {:callback_child, self()})
            Process.sleep(:infinity)
          end)

          raise "callback error after spawn"

        :monitor ->
          Process.monitor(Process.whereis(:init))
          default

        :link ->
          Process.link(:persistent_term.get({__MODULE__, :test_owner}))
          default

        :monitor_transient ->
          reference = Process.monitor(Process.whereis(:init))
          Process.demonitor(reference, [:flush])
          default

        :ets ->
          :ets.new(:callback_table, [])
          default

        :ets_transient ->
          table = :ets.new(:callback_table, [])
          :ets.delete(table)
          default

        :port ->
          Port.open({:spawn_driver, ~c"ram_file_drv"}, [:binary])
          default

        :port_transient ->
          port = Port.open({:spawn_driver, ~c"ram_file_drv"}, [:binary])
          Port.close(port)
          default

        :heap ->
          _value = List.duplicate(0, 3_000_000)
          default
      end
    end
  end

  setup do
    :persistent_term.put({Backend, :test_owner}, self())

    on_exit(fn ->
      for callback <- [:backend_id, :backend_version, :validate, :plan, :finalize, :test_owner] do
        :persistent_term.erase({Backend, callback})
      end
    end)
  end

  test "returns a value only after a clean callback exit" do
    assert {:ok, "coordinator.backend"} =
             CallbackCoordinator.invoke(Backend, :backend_id, [], nil)
  end

  test "converts caught callback termination to the closed crash failure" do
    for mode <- [:throw, :exit, :error] do
      set_mode(:validate, mode)

      assert {:error, failure} =
               CallbackCoordinator.invoke(Backend, :validate, [:web, %{}], :web)

      assert failure.code == :contract_violation
      assert failure.message == "extension callback crashed", "unexpected outcome for #{mode}"
      assert [diagnostic] = failure.diagnostics
      assert diagnostic.code == :backend_validate_crash
      assert diagnostic.target == :web
    end
  end

  test "enforces the fixed admission deadline and confirms cleanup" do
    set_mode(:validate, :sleep)

    assert {:error, failure} =
             CallbackCoordinator.invoke(Backend, :validate, [:web, %{}], :web)

    assert failure.code == :contract_violation
    assert failure.message == "extension admission callback timed out"
    assert [%{code: :backend_validate_timeout}] = failure.diagnostics
    refute_receive {:DOWN, _monitor, :process, _pid, _reason}
    refute_receive {:trace, _source, _event, _detail}
    refute_receive {:trace, _source, _event, _detail, _extra}
    refute_receive {:trace_delivered, _pid, _reference}
  end

  test "applies the fixed deadline and exact diagnostic to every callback" do
    cases = [
      {:backend_id, [], nil, "extension admission callback timed out",
       :backend_backend_id_timeout},
      {:backend_version, [], nil, "extension admission callback timed out",
       :backend_backend_version_timeout},
      {:validate, [:web, %{}], :web, "extension admission callback timed out",
       :backend_validate_timeout},
      {:plan, [nil, %{}], :web, "extension plan callback timed out", :backend_plan_timeout},
      {:finalize, [nil, %{}, nil], :desktop, "extension finalize callback timed out",
       :backend_finalize_timeout}
    ]

    for {callback, arguments, target, message, diagnostic_code} <- cases do
      set_mode(callback, :sleep)

      assert {:error, failure} =
               CallbackCoordinator.invoke(Backend, callback, arguments, target)

      assert failure.message == message
      assert [%{code: ^diagnostic_code, target: ^target}] = failure.diagnostics
    end
  end

  test "converts caught termination from every callback without leaking its reason" do
    cases = [
      {:backend_id, [], nil, :backend_backend_id_crash},
      {:backend_version, [], nil, :backend_backend_version_crash},
      {:validate, [:web, %{}], :web, :backend_validate_crash},
      {:plan, [nil, %{}], :web, :backend_plan_crash},
      {:finalize, [nil, %{}, nil], :desktop, :backend_finalize_crash}
    ]

    for {callback, arguments, target, diagnostic_code} <- cases do
      set_mode(callback, :error)

      assert {:error, failure} =
               CallbackCoordinator.invoke(Backend, callback, arguments, target)

      assert failure.message == "extension callback crashed"
      assert [%{code: ^diagnostic_code, target: ^target}] = failure.diagnostics
    end
  end

  test "rejects process creation only after cleanup is confirmed" do
    set_mode(:validate, :spawn)

    assert {:error, failure} =
             CallbackCoordinator.invoke(Backend, :validate, [:desktop, %{}], :desktop)

    assert failure.code == :contract_violation
    assert failure.message == "extension callback resource limit was violated"
    assert [%{code: :backend_validate_resource}] = failure.diagnostics

    assert_receive {:callback_child, child}, 1_000
    refute Process.alive?(child)
  end

  test "rejects persistent and transient monitor, ETS, and Port actions" do
    for mode <- [:monitor, :monitor_transient, :ets, :ets_transient, :port, :port_transient] do
      set_mode(:validate, mode)

      assert {:error, failure} =
               CallbackCoordinator.invoke(Backend, :validate, [:web, %{}], :web)

      assert failure.code == :contract_violation
      assert failure.message == "extension callback resource limit was violated"
    end
  end

  test "rejects a link without terminating the coordinator owner" do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)
    set_mode(:validate, :link)

    assert {:error, failure} =
             CallbackCoordinator.invoke(Backend, :validate, [:web, %{}], :web)

    assert failure.message == "extension callback resource limit was violated"
    assert_receive {:EXIT, _callback, :killed}, 1_000
  end

  test "classifies an unlatched heap kill as a resource violation" do
    set_mode(:validate, :heap)

    assert {:error, failure} =
             CallbackCoordinator.invoke(Backend, :validate, [:web, %{}], :web)

    assert failure.code == :contract_violation
    assert failure.message == "extension callback resource limit was violated"
  end

  test "resource violation wins a race with a caught callback error" do
    set_mode(:validate, :spawn_then_error)

    assert {:error, failure} =
             CallbackCoordinator.invoke(Backend, :validate, [:web, %{}], :web)

    assert failure.message == "extension callback resource limit was violated"
    assert [%{code: :backend_validate_resource}] = failure.diagnostics
    assert_receive {:callback_child, child}, 1_000
    refute Process.alive?(child)
  end

  test "does not consume unrelated caller messages" do
    send(self(), {:unrelated, make_ref()})

    assert {:ok, "coordinator.backend"} =
             CallbackCoordinator.invoke(Backend, :backend_id, [], nil)

    assert_receive {:unrelated, reference}
    assert is_reference(reference)
  end

  test "invokes and validates plan and finalize through the same coordinator" do
    context = context(:web)
    result = execution_result()

    assert {:ok, %ExternalPlan{expected_manifest: "manifest.json"}} =
             TargetBackend.invoke_plan(Backend, context, %{})

    assert {:ok, %ExternalArtifact{manifest: "manifest.json"}} =
             TargetBackend.invoke_finalize(Backend, context, %{}, result)
  end

  test "rejects malformed and target-mismatched backend failures" do
    context = context(:desktop)

    set_mode(:plan, {:value, :invalid})

    assert {:error, %{code: :contract_violation, target: :desktop, diagnostics: [diagnostic]}} =
             TargetBackend.invoke_plan(Backend, context, %{})

    assert diagnostic.code == :backend_plan_return

    wrong_target =
      Rekindle.Failure.new!(
        target: :web,
        stage: :execution,
        code: :cargo_failed,
        message: "backend build failed"
      )

    set_mode(:plan, {:value, {:error, wrong_target}})

    assert {:error, %{code: :contract_violation, target: :desktop}} =
             TargetBackend.invoke_plan(Backend, context, %{})
  end

  defp set_mode(callback, mode), do: :persistent_term.put({Backend, callback}, mode)

  defp context(target) do
    %BackendContext{
      otp_app: :example,
      application_id: "example",
      rekindle_version: "0.1.0",
      project_session: String.duplicate("0", 32),
      target: target,
      package: "example_ui",
      binary: "example",
      profile: "dev",
      features: [Atom.to_string(target)],
      integration_identity: %{"target" => Atom.to_string(target)},
      host_descriptor: if(target == :web, do: %{"kind" => "body_owned"}, else: nil),
      graphics_requirement: if(target == :web, do: %{"v" => 2}, else: nil),
      host_requirements_digest: String.duplicate("a", 64),
      public_root: nil,
      hot_styles: [],
      runtime_manifest: nil,
      source_revision: 1,
      project_root: Rekindle.QualifiedPath.issue(:read),
      client_root: Rekindle.QualifiedPath.issue(:read),
      staging_root: Rekindle.QualifiedPath.issue(:read_write),
      limits: %{},
      diagnostic_sink: self(),
      backend_id: "coordinator.backend",
      backend_version: "1",
      options_digest: String.duplicate("b", 64)
    }
  end

  defp execution_result do
    %ExecutionResult{
      build_key: String.duplicate("c", 64),
      outcome: :exited,
      exit_code: 0,
      signal: nil,
      duration_ms: 1,
      stdout_tail: <<>>,
      stderr_tail: <<>>,
      discarded_bytes: %{stdout: 0, stderr: 0},
      cleanup: :confirmed
    }
  end
end
