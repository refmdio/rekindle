defmodule Rekindle.BuildFacadeTest do
  use ExUnit.Case, async: false

  alias Rekindle.Config.{BuildConfig, DevConfig, Project}
  alias Rekindle.{BuildFacade, BuildResult, Failure, GenerationRef, ProjectSession}

  @otp_app :rekindle_build_facade_test
  @digest String.duplicate("a", 64)
  @generation String.duplicate("b", 32)

  defmodule Handler do
    @behaviour Rekindle.TargetHandler

    @impl true
    def build(project, mode, revision) do
      send(Application.fetch_env!(project.otp_app, :test_owner), {:build_called, mode, revision})
      Application.fetch_env!(project.otp_app, :build_result)
    end
  end

  defmodule RaisingHandler do
    @behaviour Rekindle.TargetHandler

    @impl true
    def build(_project, _mode, _revision), do: raise("handler detail")
  end

  defmodule AdmittedProjectHandler do
    @behaviour Rekindle.TargetHandler

    @impl true
    def build(project, _mode, _revision) do
      owner = Application.fetch_env!(:rekindle_build_facade_test, :test_owner)
      send(owner, {:admitted_project, project.otp_app, project.application_id})
      Application.fetch_env!(:rekindle_build_facade_test, :build_result)
    end
  end

  setup do
    Application.put_env(@otp_app, :test_owner, self())

    on_exit(fn ->
      Application.delete_env(@otp_app, :test_owner)
      Application.delete_env(@otp_app, :build_result)
    end)

    :ok
  end

  test "dispatches both targets and modes through one typed handler boundary" do
    for target <- [:web, :desktop], mode <- [:dev, :release] do
      result = build_result(target, mode)
      Application.put_env(@otp_app, :build_result, {:ok, result})

      assert {:ok, ^result} =
               BuildFacade.build(@otp_app, target, mode,
                 build_runner: build_runner(1),
                 handlers: %{target => Handler},
                 load_project: loader([target])
               )

      assert_receive {:build_called, ^mode, 1}
      refute_received :projected
      refute_received :activated
      refute_received :desktop_started
    end
  end

  test "returns only validated current generation snapshots" do
    generation = generation(:web)

    assert {:ok, ^generation} =
             BuildFacade.current(@otp_app, :web,
               current_reader: fn _root, :web -> {:ok, generation} end,
               load_project: loader([:web])
             )

    assert :none =
             BuildFacade.current(@otp_app, :web,
               current_reader: fn _root, :web -> :none end,
               load_project: loader([:web])
             )

    assert :none =
             BuildFacade.current(@otp_app, :web,
               current_reader: fn _root, :web -> {:ok, generation(:desktop)} end,
               load_project: loader([:web])
             )

    refute function_exported?(Handler, :current, 1)
  end

  test "rejects undeclared, unavailable, mismatched, malformed, and raised handlers" do
    assert {:error, %{code: :target_undeclared, stage: :configuration}} =
             BuildFacade.build(@otp_app, :web, :dev,
               build_runner: build_runner(1),
               handlers: %{web: Handler},
               load_project: loader([:desktop])
             )

    assert {:error, %{code: :contract_violation, stage: :internal}} =
             BuildFacade.build(@otp_app, :web, :dev,
               build_runner: build_runner(1),
               handlers: %{},
               load_project: loader([:web])
             )

    Application.put_env(@otp_app, :build_result, {:ok, build_result(:desktop, :dev)})

    assert {:error, %{code: :contract_violation, stage: :internal}} =
             BuildFacade.build(@otp_app, :web, :dev,
               build_runner: build_runner(1),
               handlers: %{web: Handler},
               load_project: loader([:web])
             )

    Application.put_env(@otp_app, :build_result, :invalid)

    assert {:error, %{code: :contract_violation, stage: :internal}} =
             BuildFacade.build(@otp_app, :web, :dev,
               build_runner: build_runner(1),
               handlers: %{web: Handler},
               load_project: loader([:web])
             )

    valid = build_result(:web, :dev)
    Application.put_env(@otp_app, :build_result, {:ok, %{valid | support_level: :experimental}})

    assert {:error, %{code: :contract_violation, stage: :internal}} =
             BuildFacade.build(@otp_app, :web, :dev,
               build_runner: build_runner(1),
               handlers: %{web: Handler},
               load_project: loader([:web])
             )

    assert {:error, %{code: :contract_violation, stage: :internal}} =
             BuildFacade.build(@otp_app, :web, :dev,
               build_runner: build_runner(1),
               handlers: %{web: RaisingHandler},
               load_project: loader([:web])
             )

    assert :none =
             BuildFacade.current(@otp_app, :web,
               current_reader: fn _root, _target -> throw(:core_detail) end,
               load_project: loader([:web])
             )
  end

  test "preserves sanitized expected failures" do
    failure =
      Failure.new!(
        target: :web,
        stage: :execution,
        code: :cargo_failed,
        message: "Cargo failed"
      )

    Application.put_env(@otp_app, :build_result, {:error, failure})

    assert {:error, ^failure} =
             BuildFacade.build(@otp_app, :web, :dev,
               build_runner: build_runner(1),
               handlers: %{web: Handler},
               load_project: loader([:web])
             )
  end

  test "public APIs validate their closed arguments before dispatch" do
    invalid_builds = [
      {@otp_app, :web, [mode: :other]},
      {@otp_app, :web, [mode: :dev, extra: true]},
      {nil, :web, [mode: :dev]},
      {@otp_app, :other, [mode: :dev]},
      {@otp_app, :web, %{mode: :dev}}
    ]

    for {otp_app, target, options} <- invalid_builds do
      assert_raise ArgumentError, fn -> Rekindle.build(otp_app, target, options) end
    end

    for {otp_app, target} <- [{nil, :web}, {@otp_app, :other}, {"app", :desktop}] do
      assert_raise ArgumentError, fn -> Rekindle.current(otp_app, target) end
    end

    valid_app = :rekindle_unconfigured_public_api_test

    assert {:error, %Failure{stage: :configuration}} =
             Rekindle.build(valid_app, :web, mode: :dev)

    assert :none = Rekindle.current(valid_app, :web)
  end

  test "live state and builds reject a different application at the same root" do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-build-facade-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    live = %{project([:web]) | project_root: root, application_id: "admitted"}
    foreign_app = :rekindle_build_facade_foreign
    foreign = %{live | otp_app: foreign_app, application_id: "foreign"}

    on_exit(fn -> File.rm_rf(root) end)

    state =
      start_supervised!({Rekindle.RuntimeState, project: live},
        id: {:runtime_state, make_ref()}
      )

    start_supervised!({ProjectSession, project: live}, id: {:project_session, make_ref()})

    generation = generation(:web)
    assert :ok = Rekindle.RuntimeState.put_current(state, generation)

    assert :none =
             BuildFacade.current(foreign_app, :web,
               load_project: fn ^foreign_app -> {:ok, foreign} end
             )

    Application.put_env(@otp_app, :build_result, {:ok, build_result(:web, :dev)})

    assert {:error, %{code: :unexpected_state}} =
             BuildFacade.build(foreign_app, :web, :dev,
               handlers: %{web: AdmittedProjectHandler},
               load_project: fn ^foreign_app -> {:ok, foreign} end
             )

    refute_receive {:admitted_project, ^foreign_app, _application_id}

    request_model = %{live | application_id: "fresh-unadmitted"}

    assert {:ok, %BuildResult{}} =
             BuildFacade.build(@otp_app, :web, :dev,
               handlers: %{web: AdmittedProjectHandler},
               load_project: fn @otp_app -> {:ok, request_model} end
             )

    assert_receive {:admitted_project, @otp_app, "admitted"}
  end

  defp loader(targets) do
    project = project(targets)
    fn @otp_app -> {:ok, project} end
  end

  defp build_runner(revision) do
    fn _root, _target, executor -> executor.(revision) end
  end

  defp project(targets) do
    %Project{
      otp_app: @otp_app,
      application_id: "rekindle-build-facade-test",
      project_root: File.cwd!(),
      build: %BuildConfig{
        schema: 1,
        client: "client",
        targets: Map.new(targets, &{&1, %{backend: :canonical}}),
        cache: %{},
        process: %{}
      },
      dev: %DevConfig{
        schema: 1,
        enabled: true,
        targets: targets,
        endpoint: nil,
        accepted_origins: nil,
        debounce_ms: 75,
        diagnostic_limit: 512,
        browser_message_bytes: 1_048_576,
        browser_startup_timeout_ms: 15_000,
        handoff_bytes: 1_048_576,
        snapshot_timeout_ms: 1_000,
        restore_timeout_ms: 1_000
      }
    }
  end

  defp build_result(target, mode) do
    {:ok, result} =
      BuildResult.new(
        target: target,
        support_level: :qualified,
        mode: mode,
        source_revision: 1,
        build_key: @digest,
        generation: generation(target),
        duration_ms: 10,
        diagnostics: []
      )

    result
  end

  defp generation(target) do
    {:ok, generation} =
      GenerationRef.new(
        target: target,
        support_level: :qualified,
        generation_id: @generation,
        artifact_id: @digest,
        profile: "dev",
        manifest_digest: @digest
      )

    generation
  end
end
