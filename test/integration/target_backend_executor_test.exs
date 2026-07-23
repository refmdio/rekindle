defmodule Rekindle.TargetBackendExecutorTest do
  use ExUnit.Case, async: false

  alias Rekindle.ArtifactStore
  alias Rekindle.Config.ProcessPolicy
  alias Rekindle.ProcessRunner

  alias Rekindle.{
    AdmittedSeal,
    BackendContext,
    CanonicalValue,
    ExternalArtifact,
    ExternalPlan,
    QualifiedPath,
    TargetBackend
  }

  @app :rekindle_target_backend_executor_test
  defmodule Adapter do
    @behaviour Rekindle.ProcessRunner.Adapter

    @impl true
    def run_exec(_helper, spawn, _state, options) do
      :ok = Keyword.fetch!(options, :after_handshake).(self())
      mode = Application.get_env(:rekindle_target_backend_executor_test, :mode, :valid)

      case mode do
        lifecycle when lifecycle in [:timeout, :cancel] ->
          notify_waiting(lifecycle)

          receive do
            :cancel -> terminal(0, :confirmed, "", "")
          end

        :helper_crash ->
          raise "helper crashed"

        :cleanup_unconfirmed ->
          terminal(0, :uncertain, "", "")

        :nonzero ->
          :ok = Rekindle.TargetBackendExecutorTest.ManifestWriter.write(spawn)
          terminal(17, :confirmed, "", "extension failed")

        _ ->
          :ok = Rekindle.TargetBackendExecutorTest.ManifestWriter.write(spawn)
          terminal(0, :confirmed, stdout(mode), "")
      end
    end

    @impl true
    def cancel(worker, _header) when is_pid(worker) do
      send(worker, :cancel)
      :ok
    end

    defp terminal(code, cleanup, stdout, stderr) do
      {:ok,
       %{
         outcome: :exited,
         code: code,
         signal: nil,
         cleanup: cleanup,
         discarded_stdout: 0,
         discarded_stderr: 0
       }, stdout, stderr}
    end

    defp stdout(:cargo_json) do
      Jason.encode!(%{
        "reason" => "compiler-message",
        "message" => %{
          "level" => "warning",
          "message" => "extension warning",
          "rendered" => "warning: extension warning"
        }
      }) <> "\n"
    end

    defp stdout(_mode), do: ""

    defp notify_waiting(mode) do
      if owner = Application.get_env(:rekindle_target_backend_executor_test, :owner) do
        send(owner, {:adapter_waiting, mode, self()})
      end
    end
  end

  defmodule ManifestWriter do
    alias Rekindle.CanonicalValue
    alias Rekindle.SealedArtifact.Identity

    @app :rekindle_target_backend_executor_test

    def write(spawn) do
      env = Map.new(spawn["env_set"], fn [name, value] -> {name, value} end)
      staging = spawn["cwd"]

      if Map.fetch!(env, "REKINDLE_EXPECTED_MANIFEST") == "rekindle-web-manifest-v2.json",
        do: write_web(staging, env),
        else: write_desktop(staging, env)
    end

    defp write_desktop(staging, env) do
      executable = "extension application"
      executable_digest = sha256(executable)
      File.write!(Path.join(staging, "application"), executable)
      File.chmod!(Path.join(staging, "application"), 0o700)

      executable_identity = %{
        "path" => "application",
        "sha256" => executable_digest,
        "size" => byte_size(executable),
        "mode" => "executable_owner"
      }

      base = %{
        "contract_version" => 2,
        "rekindle_version" => "0.1.0",
        "application_id" => "executor_test",
        "target" => "desktop",
        "artifact_id" => "pending",
        "build" => %{
          "build_key" => Map.fetch!(env, "REKINDLE_BUILD_KEY"),
          "profile" => "dev",
          "package" => "executor_ui",
          "binary" => "executor",
          "features" => ["desktop"]
        },
        "platform" => %{
          "os" => "linux",
          "arch" => "x86_64",
          "target_triple" => "x86_64-unknown-linux-gnu"
        },
        "producer" => producer(),
        "host_requirements" => Rekindle.ManifestFixture.host_requirements(:desktop),
        "executable" => executable_identity,
        "runtime" => %{"readiness" => "startup_grace", "handoff" => "disabled"}
      }

      {:ok, artifact_id} = Identity.derive(:desktop, base)
      base = %{base | "artifact_id" => artifact_id}
      manifest = Map.put(base, "manifest_digest", manifest_digest(base))

      File.write!(
        Path.join(staging, "rekindle-native-manifest-v2.json"),
        CanonicalValue.encode!(manifest)
      )

      :ok
    end

    defp write_web(staging, env) do
      members = [
        web_member(staging, "entry.js", "bootstrap", "import('./app.js')"),
        web_member(staging, "app.js", "javascript", "fetch('app_bg.wasm')"),
        web_member(staging, "app_bg.wasm", "wasm", <<0, 97, 115, 109>>)
      ]

      base = %{
        "contract_version" => 2,
        "rekindle_version" => "0.1.0",
        "application_id" => "executor_test",
        "target" => "web",
        "artifact_id" => "pending",
        "build" => %{
          "build_key" => Map.fetch!(env, "REKINDLE_BUILD_KEY"),
          "profile" => "dev",
          "package" => "executor_ui",
          "binary" => "executor",
          "features" => ["web"]
        },
        "producer" => producer(),
        "host_requirements" => Rekindle.ManifestFixture.host_requirements(:web),
        "entry" => "entry.js",
        "hot_styles" => [],
        "members" => Enum.sort_by(members, & &1["path"]),
        "edges" => [
          %{"from" => "app.js", "to" => "app_bg.wasm", "kind" => "wasm_url"},
          %{"from" => "entry.js", "to" => "app.js", "kind" => "dynamic_import"}
        ]
      }

      {:ok, artifact_id} = Identity.derive(:web, base)
      base = %{base | "artifact_id" => artifact_id}
      manifest = Map.put(base, "manifest_digest", manifest_digest(:web, base))

      File.write!(
        Path.join(staging, "rekindle-web-manifest-v2.json"),
        CanonicalValue.encode!(manifest)
      )

      :ok
    end

    defp web_member(staging, path, role, bytes) do
      destination = Path.join([staging, "members", path])
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, bytes)

      {mime, cache} =
        case role do
          "bootstrap" -> {"text/javascript; charset=utf-8", "no_cache"}
          "javascript" -> {"text/javascript; charset=utf-8", "immutable"}
          "wasm" -> {"application/wasm", "immutable"}
        end

      %{
        "path" => path,
        "role" => role,
        "sha256" => sha256(bytes),
        "size" => byte_size(bytes),
        "mime" => mime,
        "cache" => cache,
        "source_map" => nil
      }
    end

    defp producer do
      producer = %{
        "kind" => "extension",
        "backend_id" => "executor.backend",
        "backend_version" => "1.0.0",
        "options_digest" => Application.fetch_env!(@app, :options_digest)
      }

      if Application.get_env(@app, :mode, :valid) == :producer_mismatch,
        do: %{producer | "backend_version" => "wrong"},
        else: producer
    end

    defp sha256(bytes),
      do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    defp manifest_digest(manifest), do: manifest_digest(:desktop, manifest)

    defp manifest_digest(target, manifest) do
      domain =
        if target == :web,
          do: "rekindle-web-manifest-v2\0",
          else: "rekindle-native-manifest-v2\0"

      :crypto.hash(
        :sha256,
        domain <> CanonicalValue.encode!(manifest)
      )
      |> Base.encode16(case: :lower)
    end
  end

  defmodule Backend do
    @behaviour Rekindle.TargetBackend
    @app :rekindle_target_backend_executor_test

    @impl true
    def backend_id, do: "executor.backend"

    @impl true
    def backend_version, do: "1.0.0"

    @impl true
    def validate(_target, options), do: {:ok, options}

    @impl true
    def plan(context, _options) do
      {:ok, project} = QualifiedPath.resolve(context.project_root, :read)
      mode = Application.get_env(@app, :mode, :valid)

      executable =
        if mode == :outside,
          do: "/bin/true",
          else: Path.join(project, "bin/build")

      env_set =
        if mode == :reserved_env,
          do: [%{name: "REKINDLE_BUILD_KEY", value: "forged", secret: false}],
          else: [%{name: "MODE", value: "test", secret: false}]

      expected_manifest =
        if mode == :wrong_manifest,
          do: "other.json",
          else:
            if(context.target == :web,
              do: "rekindle-web-manifest-v2.json",
              else: "rekindle-native-manifest-v2.json"
            )

      {:ok,
       %ExternalPlan{
         executable: executable,
         argv: ["--target", Atom.to_string(context.target)],
         cwd: %{root: :staging, path: "."},
         env_mode: :replace,
         env_set: env_set,
         diagnostic_mode: if(mode == :cargo_json, do: :cargo_json, else: :opaque),
         timeout_ms: if(mode == :timeout, do: 1_000, else: 5_000),
         expected_manifest: expected_manifest
       }}
    end

    @impl true
    def finalize(context, _options, execution) do
      if execution.outcome == :exited and execution.exit_code == 0 do
        {:ok,
         %ExternalArtifact{
           manifest:
             if(context.target == :web,
               do: "rekindle-web-manifest-v2.json",
               else: "rekindle-native-manifest-v2.json"
             ),
           supplemental_diagnostics: []
         }}
      else
        {:error,
         Rekindle.Failure.new!(
           target: context.target,
           stage: :execution,
           code: :cargo_failed,
           message: "Extension command failed"
         )}
      end
    end
  end

  setup do
    root = temp_dir!("rekindle-extension-executor")
    project = Path.join(root, "project")
    client = Path.join(project, "client")
    cache = Path.join(root, ".rekindle")
    File.mkdir_p!(Path.join(project, "bin"))
    File.mkdir_p!(client)
    File.write!(Path.join(project, "bin/build"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(project, "bin/build"), 0o700)

    store =
      start_supervised!(
        {ArtifactStore, root: cache, retained_generations: 3, max_generation_bytes: 67_108_864}
      )

    runner = start_supervised!({ProcessRunner, adapter: Adapter})
    {:ok, desktop_admission} = TargetBackend.admit(Backend, :desktop, %{})
    {:ok, web_admission} = TargetBackend.admit(Backend, :web, %{})
    Application.put_env(@app, :mode, :valid)
    Application.put_env(@app, :owner, self())
    Application.put_env(@app, :options_digest, desktop_admission.options_digest)

    on_exit(fn ->
      Application.delete_env(@app, :mode)
      Application.delete_env(@app, :owner)
      Application.delete_env(@app, :options_digest)
      remove_tree(root)
    end)

    %{
      root: root,
      project: project,
      client: client,
      cache: cache,
      store: store,
      runner: runner,
      admissions: %{desktop: desktop_admission, web: web_admission}
    }
  end

  test "executes, revalidates, seals, and admits one inactive extension artifact", state do
    assert {:ok, admitted, execution, []} = execute(state)
    assert execution.outcome == :exited
    assert execution.exit_code == 0
    assert execution.cleanup == :confirmed

    assert {:ok, value} = AdmittedSeal.fetch(admitted)
    assert value.target == :desktop
    assert value.source_revision == 7
    assert value.producer.kind == :extension
    assert value.producer.attributes["backend_id"] == "executor.backend"
    assert value.seal_result == :sealed
    assert :none = ArtifactStore.current(state.store, :desktop)
  end

  test "uses the same inactive admission boundary for Web artifacts", state do
    assert {:ok, admitted, execution, []} = execute(state, :web)
    assert execution.outcome == :exited

    assert {:ok, value} = AdmittedSeal.fetch(admitted)
    assert value.target == :web
    assert value.source_revision == 7
    assert value.producer.kind == :extension
    assert :none = ArtifactStore.current(state.store, :web)
  end

  test "rejects an executable outside core-qualified roots before process execution", state do
    Application.put_env(@app, :mode, :outside)
    assert {:error, %{code: :contract_violation}} = execute(state)
    assert staging_empty?(state.cache)
  end

  test "rejects producer echo changes and removes the failed staging attempt", state do
    Application.put_env(@app, :mode, :producer_mismatch)
    assert {:error, %{code: :manifest_invalid}} = execute(state)
    assert staging_empty?(state.cache)
    assert :none = ArtifactStore.current(state.store, :desktop)
  end

  test "removes staging when context construction raises", state do
    builder = fn _staging -> raise "context construction failed" end

    assert {:error, %{code: :contract_violation}} = execute(state, :desktop, builder)
    assert staging_empty?(state.cache)
  end

  test "removes staging when context construction throws", state do
    builder = fn _staging -> throw(:context_construction_failed) end

    assert {:error, %{code: :contract_violation}} = execute(state, :desktop, builder)
    assert staging_empty?(state.cache)
  end

  test "owns reserved execution identity variables and rejects backend overrides", state do
    Application.put_env(@app, :mode, :reserved_env)
    assert {:error, %{code: :contract_violation}} = execute(state)
    assert staging_empty?(state.cache)
  end

  test "uses the declared canonical manifest path as the sole artifact authority", state do
    Application.put_env(@app, :mode, :wrong_manifest)
    assert {:error, %{code: :manifest_invalid}} = execute(state)
    assert staging_empty?(state.cache)
  end

  test "decodes bounded Cargo JSON diagnostics without selecting Cargo artifacts", state do
    Application.put_env(@app, :mode, :cargo_json)

    assert {:ok, _admitted, _execution, [diagnostic]} = execute(state)
    assert diagnostic.code == :backend_compiler
    assert diagnostic.severity == :warning
    assert diagnostic.message == "extension warning"
  end

  test "propagates a confirmed external timeout and removes every owned resource", state do
    assert_failed_execution(state, :timeout, :build_timeout)
    assert_receive {:adapter_waiting, :timeout, _worker}
  end

  test "propagates cancellation during runner shutdown and removes every owned resource", state do
    baseline = QualifiedPath.authority_size()
    Application.put_env(@app, :mode, :cancel)
    task = Task.async(fn -> execute(state) end)
    assert_receive {:adapter_waiting, :cancel, _worker}

    assert {:ok, shutdown} = ProcessRunner.begin_shutdown(state.runner)
    assert {:error, %{code: :cancelled}} = Task.await(task, 2_000)

    if is_reference(shutdown) do
      assert_receive {:rekindle_process_runner_shutdown, ^shutdown, :ok}, 1_000
    end

    assert_failed_resources(state, baseline)
  end

  test "converts a helper crash and removes every owned resource", state do
    assert_failed_execution(state, :helper_crash, :io_failed)
  end

  test "preserves an uncertain cleanup failure and removes staging authority", state do
    assert_failed_execution(state, :cleanup_unconfirmed, :cleanup_unconfirmed)
  end

  test "lets the backend convert a nonzero terminal without admitting an artifact", state do
    assert_failed_execution(state, :nonzero, :cargo_failed)
  end

  defp execute(state, target \\ :desktop, builder \\ nil) do
    builder = builder || fn staging -> context(state, staging, target) end

    TargetBackend.execute(state.admissions[target], target, builder,
      runner: state.runner,
      store: state.store,
      helper: "/bin/true",
      process: process_policy()
    )
  end

  defp assert_failed_execution(state, mode, code) do
    baseline = QualifiedPath.authority_size()
    Application.put_env(@app, :mode, mode)
    assert {:error, %{code: ^code}} = execute(state)
    assert_failed_resources(state, baseline)
  end

  defp assert_failed_resources(state, authority_baseline) do
    assert staging_empty?(state.cache)
    assert :sys.get_state(state.runner).jobs == %{}
    assert :none = ArtifactStore.current(state.store, :desktop)
    assert QualifiedPath.authority_size() == authority_baseline

    generations = Path.join([state.cache, "generations", "desktop"])
    assert File.ls!(generations) == []
  end

  defp context(state, staging, target) do
    requirements = Rekindle.ManifestFixture.host_requirements(target)

    host_digest =
      :crypto.hash(
        :sha256,
        "rekindle-host-requirements-v1\0" <> CanonicalValue.encode!(requirements)
      )
      |> Base.encode16(case: :lower)

    %BackendContext{
      otp_app: @app,
      application_id: "executor_test",
      rekindle_version: "0.1.0",
      project_session: String.duplicate("0", 32),
      target: target,
      package: "executor_ui",
      binary: "executor",
      profile: "dev",
      features: [Atom.to_string(target)],
      integration_identity: Rekindle.ManifestFixture.integration_identity(target),
      host_descriptor: requirements["host_descriptor"],
      graphics_requirement: requirements["graphics_requirement"],
      host_requirements_digest: host_digest,
      public_root: nil,
      hot_styles: [],
      runtime_manifest:
        if(target == :desktop,
          do: %{"readiness" => "startup_grace", "handoff" => "disabled"},
          else: nil
        ),
      source_revision: 7,
      project_root: QualifiedPath.issue(state.project, :read),
      client_root: QualifiedPath.issue(state.client, :read),
      staging_root: staging,
      limits: %{},
      diagnostic_sink: self(),
      backend_id: state.admissions[target].backend_id,
      backend_version: state.admissions[target].backend_version,
      options_digest: state.admissions[target].options_digest
    }
  end

  defp process_policy do
    %ProcessPolicy{
      build_timeout_ms: 5_000,
      terminate_grace_ms: 100,
      kill_grace_ms: 500,
      output_bytes_per_stream: 1_048_576,
      max_cargo_builds: 1,
      max_helper_jobs: 1
    }
  end

  defp staging_empty?(cache) do
    case File.ls(Path.join(cache, "staging")) do
      {:ok, []} -> true
      _ -> false
    end
  end

  defp temp_dir!(prefix) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{suffix}")
    File.mkdir_p!(path)
    path
  end

  defp remove_tree(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        :ok = File.chmod(path, 0o700)

        path
        |> File.ls!()
        |> Enum.each(&remove_tree(Path.join(path, &1)))

        File.rmdir(path)

      {:ok, _stat} ->
        File.rm(path)

      {:error, :enoent} ->
        :ok
    end
  end
end
