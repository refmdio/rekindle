defmodule Rekindle.ProjectSessionTest do
  use ExUnit.Case, async: false

  alias Rekindle.Config.{BuildConfig, DevConfig, Project, WebTarget}
  alias Rekindle.{BuildFacade, BuildResult, GenerationRef, ProjectSession}

  defmodule Handler do
    @behaviour Rekindle.TargetHandler
    @digest String.duplicate("a", 64)
    @generation String.duplicate("b", 32)

    @impl true
    def build(project, mode, revision) do
      owner = Application.fetch_env!(project.otp_app, :owner)
      send(owner, {:build_started, revision, self()})

      case Application.fetch_env!(project.otp_app, :execute).(revision) do
        :wait ->
          receive do
            :continue -> result(mode, revision)
          end

        :return ->
          result(mode, revision)
      end
    end

    defp result(mode, revision) do
      {:ok, generation} =
        GenerationRef.new(
          target: :web,
          support_level: :qualified,
          generation_id: @generation,
          artifact_id: @digest,
          profile: Atom.to_string(mode),
          manifest_digest: @digest
        )

      BuildResult.new(
        target: :web,
        support_level: :qualified,
        mode: mode,
        source_revision: revision,
        build_key: @digest,
        generation: generation,
        duration_ms: 1,
        diagnostics: []
      )
    end
  end

  defmodule WrongRevisionHandler do
    @behaviour Rekindle.TargetHandler

    @impl true
    def build(project, mode, revision) do
      {:ok, result} = Handler.build(project, mode, revision)
      {:ok, %{result | source_revision: revision + 1}}
    end
  end

  setup do
    otp_app = String.to_atom("rekindle_session_#{System.unique_integer([:positive])}")
    project = project(otp_app)
    Application.put_env(otp_app, :owner, self())

    on_exit(fn ->
      Application.delete_env(otp_app, :owner)
      Application.delete_env(otp_app, :execute)
      File.rm_rf!(project.project_root)
    end)

    start_supervised!({ProjectSession, project: project})
    %{otp_app: otp_app, project: project}
  end

  test "facade requests allocate revisions and supersede one running target build", context do
    Application.put_env(context.otp_app, :execute, fn
      1 -> :wait
      _revision -> :return
    end)

    options = [
      handlers: %{web: Handler},
      load_project: fn app -> {:ok, %{context.project | otp_app: app}} end
    ]

    first = Task.async(fn -> BuildFacade.build(context.otp_app, :web, :dev, options) end)
    assert_receive {:build_started, 1, first_worker}, 1_000

    second = Task.async(fn -> BuildFacade.build(context.otp_app, :web, :dev, options) end)

    assert {:error, %{code: :cancelled}} = Task.await(first, 1_000)
    assert_receive {:build_started, 2, _second_worker}, 1_000
    refute Process.alive?(first_worker)

    assert {:ok, %BuildResult{source_revision: 2, mode: :dev}} = Task.await(second, 1_000)

    assert {:ok, %BuildResult{source_revision: 3, mode: :release}} =
             BuildFacade.build(context.otp_app, :web, :release, options)
  end

  test "facade rejects a handler result that does not echo its allocated revision", context do
    Application.put_env(context.otp_app, :execute, fn _revision -> :return end)

    assert {:error, %{code: :contract_violation}} =
             BuildFacade.build(context.otp_app, :web, :dev,
               handlers: %{web: WrongRevisionHandler},
               load_project: fn _app -> {:ok, context.project} end
             )
  end

  defp project(otp_app) do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-project-session-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    target = %WebTarget{
      package: "demo_ui",
      binary: "demo",
      backend: :canonical,
      features: [],
      profiles: %{dev: "dev", release: "release"},
      public: nil,
      hot_styles: [],
      projection: %{mode: :phoenix_static, root: "priv/static/rekindle"},
      toolchain: nil,
      rust_target: nil,
      default_features: true,
      environment: nil
    }

    %Project{
      otp_app: otp_app,
      application_id: Atom.to_string(otp_app),
      project_root: root,
      build: %BuildConfig{
        schema: 1,
        client: "client",
        targets: %{web: target},
        cache: nil,
        process: nil
      },
      dev: %DevConfig{
        schema: 1,
        enabled: true,
        targets: [:web],
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
end
