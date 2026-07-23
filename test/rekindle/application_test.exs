defmodule Rekindle.ApplicationTest do
  use ExUnit.Case, async: false

  alias Rekindle.{Failure, ProjectSession, RuntimeState}

  @otp_app :rekindle_lifecycle_test

  defmodule MalformedBackend do
    @behaviour Rekindle.TargetBackend

    @impl true
    def backend_id, do: "test.malformed"

    @impl true
    def backend_version, do: "1"

    @impl true
    def validate(_target, _options), do: {:error, :malformed}

    @impl true
    def plan(_context, _options), do: raise("unused")

    @impl true
    def finalize(_context, _options, _result), do: raise("unused")
  end

  setup do
    previous_build = Application.get_env(@otp_app, :rekindle_build)
    previous_dev = Application.get_env(@otp_app, :rekindle_dev)

    Application.put_env(@otp_app, :rekindle_build, build_config())
    Application.put_env(@otp_app, :rekindle_dev, dev_config())

    on_exit(fn ->
      restore(:rekindle_build, previous_build)
      restore(:rekindle_dev, previous_dev)
    end)

    :ok
  end

  test "publishes the exact stable child specification" do
    spec = Rekindle.child_spec(otp_app: @otp_app, name: :lifecycle_project)

    assert spec == %{
             id: {Rekindle, @otp_app},
             start:
               {Rekindle.ProjectSupervisor, :start_link,
                [[otp_app: @otp_app, name: :lifecycle_project]]},
             restart: :permanent,
             shutdown: 30_000,
             type: :supervisor
           }

    assert_raise ArgumentError, fn -> Rekindle.child_spec(otp_app: @otp_app) end

    assert_raise ArgumentError, fn ->
      Rekindle.child_spec(otp_app: @otp_app, name: :x, extra: true)
    end
  end

  test "starts one idle owner and stops without external work" do
    ports_before = MapSet.new(Port.list())
    name = unique_name(:project)
    assert {:ok, supervisor} = start_supervised({Rekindle, otp_app: @otp_app, name: name})

    assert {:ok,
            %{
              otp_app: @otp_app,
              status: :idle,
              target_count: 0,
              owned_process_count: 0
            }} = RuntimeState.snapshot(File.cwd!())

    assert Process.alive?(supervisor)
    assert ports_before == MapSet.new(Port.list())
  end

  test "rejects a duplicate normalized project even under another supervisor name" do
    first = unique_name(:first)
    second = unique_name(:second)

    assert {:ok, _pid} = start_supervised({Rekindle, otp_app: @otp_app, name: first})

    assert {:error, {:already_started, _pid}} =
             start_supervised({Rekindle, otp_app: @otp_app, name: second})
  end

  test "restarts the project state owner under the same normalized identity" do
    name = unique_name(:restart)
    assert {:ok, _supervisor} = start_supervised({Rekindle, otp_app: @otp_app, name: name})

    key = {:project, File.cwd!()}
    assert [{owner, _value}] = Registry.lookup(Rekindle.RuntimeRegistry, key)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 1_000

    assert eventually(fn ->
             case Registry.lookup(Rekindle.RuntimeRegistry, key) do
               [{replacement, _value}] when replacement != owner -> Process.alive?(replacement)
               _ -> false
             end
           end)

    assert {:ok, %{status: :idle, owned_process_count: 0}} = RuntimeState.snapshot(File.cwd!())
  end

  test "restarts the complete project session boundary with a new identity" do
    name = unique_name(:session_restart)
    assert {:ok, _supervisor} = start_supervised({Rekindle, otp_app: @otp_app, name: name})

    root = File.cwd!()
    assert {:ok, first_identity} = ProjectSession.identity(root)
    [{first_session, _}] = Registry.lookup(Rekindle.RuntimeRegistry, {:session, root})
    [{first_state, _}] = Registry.lookup(Rekindle.RuntimeRegistry, {:project, root})
    [{first_events, _}] = Registry.lookup(Rekindle.RuntimeRegistry, {:events, @otp_app})

    Process.exit(first_session, :kill)

    assert eventually(fn ->
             with [{session, _}] when session != first_session <-
                    Registry.lookup(Rekindle.RuntimeRegistry, {:session, root}),
                  [{state, _}] when state != first_state <-
                    Registry.lookup(Rekindle.RuntimeRegistry, {:project, root}),
                  [{events, _}] when events != first_events <-
                    Registry.lookup(Rekindle.RuntimeRegistry, {:events, @otp_app}),
                  {:ok, identity} when identity != first_identity <- ProjectSession.identity(root) do
               true
             else
               _ -> false
             end
           end)
  end

  test "stops the owner and releases all project-scoped registrations" do
    ports_before = MapSet.new(Port.list())
    name = unique_name(:shutdown)
    child_id = {Rekindle, @otp_app}
    assert {:ok, supervisor} = start_supervised({Rekindle, otp_app: @otp_app, name: name})
    monitor = Process.monitor(supervisor)

    assert :ok = stop_supervised(child_id)
    assert_receive {:DOWN, ^monitor, :process, ^supervisor, :shutdown}, 1_000
    assert :none = RuntimeState.snapshot(File.cwd!())
    assert [] = Registry.lookup(Rekindle.RuntimeRegistry, {:events, @otp_app})
    assert ports_before == MapSet.new(Port.list())
  end

  test "fails before runtime ownership when configuration is invalid" do
    Application.put_env(@otp_app, :rekindle_build, schema: 2)

    assert {:error,
            %Failure{
              target: nil,
              stage: :configuration,
              code: :config_invalid,
              message: "Project configuration is invalid",
              diagnostics: diagnostics,
              retryable?: false
            }} =
             Rekindle.ProjectSupervisor.start_link(
               otp_app: @otp_app,
               name: unique_name(:invalid)
             )

    assert Enum.any?(diagnostics, &(&1.code == :invalid_value))
    assert :none = RuntimeState.snapshot(File.cwd!())
  end

  test "reports missing configuration through the same public failure boundary" do
    Application.delete_env(@otp_app, :rekindle_build)

    assert {:error,
            %Failure{
              target: nil,
              stage: :configuration,
              code: :config_missing,
              message: "Project configuration is missing",
              diagnostics: [%{code: :missing_key}],
              retryable?: false
            }} =
             Rekindle.ProjectSupervisor.start_link(
               otp_app: @otp_app,
               name: unique_name(:missing)
             )

    assert :none = RuntimeState.snapshot(File.cwd!())
  end

  test "reports malformed extension configuration as a contract violation" do
    build =
      build_config()
      |> Keyword.update!(:targets, fn targets ->
        Keyword.update!(targets, :desktop, fn target ->
          Keyword.put(target, :backend, module: MalformedBackend, options: %{})
        end)
      end)

    Application.put_env(@otp_app, :rekindle_build, build)

    assert {:error,
            %Failure{
              target: nil,
              stage: :internal,
              code: :contract_violation,
              message: "extension configuration error contract violation",
              diagnostics: []
            }} =
             Rekindle.ProjectSupervisor.start_link(
               otp_app: @otp_app,
               name: unique_name(:malformed_extension)
             )

    assert :none = RuntimeState.snapshot(File.cwd!())
  end

  defp build_config do
    [
      schema: 1,
      client: "lib",
      targets: [
        desktop: [
          package: "lifecycle_ui",
          binary: "lifecycle",
          toolchain: [kind: :rustup, name: "1.95.0"],
          features: ["desktop"],
          projection: [mode: :directory, root: "dist/rekindle/desktop"]
        ]
      ]
    ]
  end

  defp dev_config, do: [schema: 1, enabled: true, targets: [:desktop]]

  defp unique_name(prefix),
    do: Module.concat(__MODULE__, "#{prefix}_#{System.unique_integer([:positive])}")

  defp eventually(assertion, attempts \\ 50)
  defp eventually(_assertion, 0), do: false

  defp eventually(assertion, attempts) do
    if assertion.() do
      true
    else
      Process.sleep(10)
      eventually(assertion, attempts - 1)
    end
  end

  defp restore(key, nil), do: Application.delete_env(@otp_app, key)
  defp restore(key, value), do: Application.put_env(@otp_app, key, value)
end
