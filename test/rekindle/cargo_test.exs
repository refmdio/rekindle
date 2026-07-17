defmodule Rekindle.CargoTest do
  use ExUnit.Case, async: true

  alias Rekindle.BuildGraph.Identity
  alias Rekindle.Cargo
  alias Rekindle.Config.{DesktopTarget, EnvironmentPolicy, ProcessPolicy, WebTarget}
  alias Rekindle.{Failure, ProcessRunner, Scheduler}

  @digest String.duplicate("a", 64)
  @package_id "path+file:///project/client#client@0.1.0"

  defmodule Adapter do
    @behaviour Rekindle.ProcessRunner.Adapter

    @impl true
    def run_exec(_helper, spawn, state, options) do
      test = Keyword.fetch!(options, :test_pid)
      :ok = Keyword.fetch!(options, :after_handshake).(self())
      send(test, {:cargo_spawn, self(), spawn, state})

      receive do
        {:finish, terminal, stdout, stderr} ->
          {:ok, terminal, stdout, stderr}

        {:cancel, header} ->
          send(test, {:cargo_cancel, self(), header})

          receive do
            {:finish_cancel, terminal, stdout, stderr} ->
              {:ok, terminal, stdout, stderr}
          end
      end
    end

    @impl true
    def cancel(worker, header) do
      send(worker, {:cancel, header})
      :ok
    end

    def terminal do
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

  setup do
    root = Path.join(System.tmp_dir!(), "rekindle-cargo-#{System.unique_integer([:positive])}")
    client = Path.join(root, "client")
    target_directory = Path.join(root, "target")
    File.mkdir_p!(client)
    File.mkdir_p!(target_directory)
    File.write!(Path.join(client, "Cargo.toml"), "[package]\nname='client'\nversion='0.1.0'\n")
    on_exit(fn -> File.rm_rf!(root) end)

    runner = start_supervised!({ProcessRunner, adapter: {Adapter, test_pid: self()}})

    cargo =
      start_supervised!(
        {Cargo,
         runner: runner,
         helper: "/tmp/rekindle_toolchain",
         authority_owner: self(),
         max_cargo_builds: 2}
      )

    web_identity = identity(:web)
    web_scheduler = scheduler(:web)
    {:ok, web_authority} = Cargo.authorize(cargo, web_identity, web_scheduler)

    %{
      root: root,
      client: client,
      target_directory: target_directory,
      runner: runner,
      cargo: cargo,
      web_identity: web_identity,
      web_scheduler: web_scheduler,
      web_authority: web_authority
    }
  end

  test "metadata and Web build use one explicit canonical facade", context do
    options = base_options(context)
    assert {:ok, metadata_reference} = Cargo.metadata(context.cargo, options)
    assert_receive {:cargo_spawn, metadata_worker, metadata_spawn, _state}

    assert metadata_spawn["executable"] == %{"kind" => "path", "value" => "/usr/bin/true"}

    assert metadata_spawn["argv"] == [
             "metadata",
             "--format-version",
             "1",
             "--locked",
             "--filter-platform",
             "wasm32-unknown-unknown",
             "--manifest-path",
             Path.join(context.client, "Cargo.toml")
           ]

    assert metadata_spawn["env_set"] == [
             ["CARGO_TARGET_DIR", context.target_directory],
             ["MODE", "test"]
           ]

    send(metadata_worker, {:finish, Adapter.terminal(), Jason.encode!(metadata_map(context)), ""})
    assert_receive {:rekindle_cargo_ready, ^metadata_reference}
    assert {:ok, metadata} = Cargo.result(context.cargo, metadata_reference, options[:authority])
    assert metadata.inventory.selected_package.id == @package_id

    artifact = Path.join(context.target_directory, "wasm32-unknown-unknown/dev/web.wasm")
    File.mkdir_p!(Path.dirname(artifact))
    File.write!(artifact, "wasm-bytes")

    build_options = Keyword.put(options, :inventory, metadata.inventory)
    assert {:ok, build_reference} = Cargo.build(context.cargo, build_options)
    assert_receive {:cargo_spawn, build_worker, build_spawn, _state}
    assert "--message-format=json-render-diagnostics" in build_spawn["argv"]

    assert Enum.chunk_every(build_spawn["argv"], 2, 1)
           |> Enum.any?(&(&1 == ["--package", "client"]))

    assert Enum.chunk_every(build_spawn["argv"], 2, 1) |> Enum.any?(&(&1 == ["--bin", "web"]))

    output =
      [artifact_message(artifact), %{"reason" => "build-finished", "success" => true}]
      |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))

    send(build_worker, {:finish, Adapter.terminal(), output, "warning from cargo"})
    assert_receive {:rekindle_cargo_ready, ^build_reference}
    assert {:ok, build} = Cargo.result(context.cargo, build_reference, options[:authority])
    assert build.build_key == context.web_identity.key
    assert build.artifact.path == artifact
    assert build.artifact.sha256 == sha256("wasm-bytes")
    assert Enum.any?(build.diagnostics, &(&1.code == :cargo_tool_output))
  end

  test "same cache work reports bounded contention", context do
    options = base_options(context)
    assert {:ok, reference} = Cargo.metadata(context.cargo, options)
    assert_receive {:cargo_spawn, worker, _spawn, _state}
    assert {:busy, :cache_key} = Cargo.metadata(context.cargo, options)
    send(worker, {:finish, Adapter.terminal(), Jason.encode!(metadata_map(context)), ""})
    assert_receive {:rekindle_cargo_ready, ^reference}
    assert {:ok, _metadata} = Cargo.result(context.cargo, reference, options[:authority])
  end

  test "completed results retain exactly the configured execution capacity", context do
    first_options = base_options(context)
    second_directory = Path.join(context.root, "target-second")
    third_directory = Path.join(context.root, "target-third")
    File.mkdir_p!(second_directory)
    File.mkdir_p!(third_directory)

    second_options = Keyword.put(first_options, :target_directory, second_directory)
    third_options = Keyword.put(first_options, :target_directory, third_directory)

    assert {:ok, first_reference} = Cargo.metadata(context.cargo, first_options)
    assert_receive {:cargo_spawn, first_worker, _spawn, _state}
    assert {:busy, :capacity} = Cargo.metadata(context.cargo, second_options)
    refute_receive {:cargo_spawn, _worker, _spawn, _state}

    send(
      first_worker,
      {:finish, Adapter.terminal(), Jason.encode!(metadata_map(context)), ""}
    )

    assert_receive {:rekindle_cargo_ready, ^first_reference}

    assert {:ok, second_reference} = Cargo.metadata(context.cargo, second_options)
    assert_receive {:cargo_spawn, second_worker, _spawn, _state}

    send(
      second_worker,
      {:finish, Adapter.terminal(), Jason.encode!(metadata_map(context)), ""}
    )

    assert_receive {:rekindle_cargo_ready, ^second_reference}
    assert {:busy, :capacity} = Cargo.metadata(context.cargo, third_options)

    for attempt <- 1..64 do
      directory = Path.join(context.root, "target-blocked-#{attempt}")
      File.mkdir_p!(directory)

      assert {:busy, :capacity} =
               Cargo.metadata(
                 context.cargo,
                 Keyword.put(first_options, :target_directory, directory)
               )
    end

    state = :sys.get_state(context.cargo)
    assert map_size(state.completed) == 2
    assert map_size(state.pool.cargo) == 2
    assert state.pool.helpers == MapSet.new()

    assert {:ok, _metadata} =
             Cargo.result(context.cargo, first_reference, context.web_authority)

    assert {:ok, third_reference} = Cargo.metadata(context.cargo, third_options)
    assert_receive {:cargo_spawn, third_worker, _spawn, _state}

    send(
      third_worker,
      {:finish, Adapter.terminal(), Jason.encode!(metadata_map(context)), ""}
    )

    assert_receive {:rekindle_cargo_ready, ^third_reference}
    state = :sys.get_state(context.cargo)
    assert map_size(state.completed) == 2
    assert map_size(state.pool.cargo) == 2
    assert state.pool.helpers == MapSet.new()
  end

  test "consumed jobs and successive revisions keep lifecycle state bounded", context do
    first_authority = context.web_authority

    latest_authority =
      Enum.reduce(1..64, first_authority, fn revision, _previous_authority ->
        scheduler = scheduler(:web, revision)
        identity = identity(:web, "revision-#{revision}")
        assert {:ok, authority} = Cargo.authorize(context.cargo, identity, scheduler)

        options = Keyword.put(base_options(context), :authority, authority)
        assert {:ok, reference} = Cargo.metadata(context.cargo, options)
        assert_receive {:cargo_spawn, worker, _spawn, _state}

        send(worker, {:finish, Adapter.terminal(), Jason.encode!(metadata_map(context)), ""})
        assert_receive {:rekindle_cargo_ready, ^reference}
        assert {:ok, _metadata} = Cargo.result(context.cargo, reference, authority)
        authority
      end)

    state = :sys.get_state(context.cargo)
    assert state.completed == %{}
    assert state.pool.cargo == %{}
    assert map_size(state.latest_revisions) == 1
    assert map_size(state.identities) == 1
    assert map_size(state.authorities) == 1
    assert Map.has_key?(state.authorities, latest_authority)

    assert {:error, %{code: :cargo_protocol}} =
             Cargo.metadata(
               context.cargo,
               Keyword.put(base_options(context), :authority, first_authority)
             )
  end

  test "toolchain paths are qualified before a runner job exists", context do
    config = %{
      web_config()
      | toolchain: %{
          kind: :path,
          cargo: "/missing/cargo",
          rustc: "/missing/rustc",
          identity: "bad"
        }
    }

    assert {:error, %{code: :tool_missing}} =
             Cargo.metadata(context.cargo, Keyword.put(base_options(context), :config, config))

    refute_receive {:cargo_spawn, _worker, _spawn, _state}
  end

  test "execution rejects forged identities and target mismatches", context do
    forged = %{context.web_identity | key: @digest}

    assert {:error, %{code: :cargo_protocol}} =
             Cargo.authorize(context.cargo, forged, context.web_scheduler)

    assert {:error, %{code: :cargo_protocol}} =
             Cargo.authorize(context.cargo, identity(:desktop), context.web_scheduler)

    refute_receive {:cargo_spawn, _worker, _spawn, _state}
  end

  test "execution rejects a scheduler snapshot with newer source work", context do
    assert {:ok, changed, [{:cancel, 1}]} =
             Scheduler.change(context.web_scheduler, [:cargo_web], 1)

    assert {:error, %{code: :cargo_protocol}} =
             Cargo.authorize(context.cargo, context.web_identity, changed)

    refute_receive {:cargo_spawn, _worker, _spawn, _state}
  end

  test "one source revision cannot change its canonical build identity", context do
    changed_identity = identity(:web, "different-inputs-in-same-revision")

    assert {:error, %{code: :cargo_protocol}} =
             Cargo.authorize(context.cargo, changed_identity, context.web_scheduler)

    refute_receive {:cargo_spawn, _worker, _spawn, _state}
  end

  test "only the configured coordinator can issue execution authority", context do
    task =
      Task.async(fn ->
        Cargo.authorize(context.cargo, context.web_identity, context.web_scheduler)
      end)

    assert {:error, %{code: :cargo_protocol}} = Task.await(task)

    assert {:error, %{code: :cargo_protocol}} =
             Cargo.metadata(
               context.cargo,
               Keyword.put(base_options(context), :authority, make_ref())
             )

    refute_receive {:cargo_spawn, _worker, _spawn, _state}
  end

  test "request envelopes cannot impersonate the configured coordinator", context do
    owner = self()
    options = base_options(context)

    task =
      Task.async(fn ->
        messages = [
          {:authorize, owner, context.web_identity, context.web_scheduler},
          {:start, owner, :metadata, options},
          {:supersede, owner, context.web_authority, context.web_scheduler},
          {:result, owner, make_ref(), context.web_authority},
          {:cancel, owner, make_ref(), :caller}
        ]

        Enum.map(messages, &GenServer.call(context.cargo, &1))
      end)

    for response <- Task.await(task) do
      assert {:error, %{code: :cargo_protocol}} = response
    end

    refute_receive {:cargo_spawn, _worker, _spawn, _state}
  end

  test "only the configured coordinator can authorize a completed result", context do
    options = base_options(context)
    assert {:ok, reference} = Cargo.metadata(context.cargo, options)
    assert_receive {:cargo_spawn, worker, _spawn, _state}
    send(worker, {:finish, Adapter.terminal(), Jason.encode!(metadata_map(context)), ""})
    assert_receive {:rekindle_cargo_ready, ^reference}

    task =
      Task.async(fn ->
        Cargo.result(context.cargo, reference, context.web_authority)
      end)

    assert {:error, %{code: :cargo_protocol}} = Task.await(task)

    assert {:ok, _metadata} =
             Cargo.result(context.cargo, reference, context.web_authority)
  end

  test "supersession revokes output that completed before invalidation", context do
    options = base_options(context)
    assert {:ok, reference} = Cargo.metadata(context.cargo, options)
    assert_receive {:cargo_spawn, worker, _spawn, _state}
    send(worker, {:finish, Adapter.terminal(), Jason.encode!(metadata_map(context)), ""})
    assert_receive {:rekindle_cargo_ready, ^reference}

    assert {:ok, changed, [{:cancel, 1}]} =
             Scheduler.change(context.web_scheduler, [:cargo_web], 1)

    assert :ok = Cargo.supersede(context.cargo, context.web_authority, changed)

    assert {:error, %{code: :cancelled}} =
             Cargo.result(context.cargo, reference, context.web_authority)
  end

  test "a result claimed before a later invalidation remains the ordered outcome", context do
    options = base_options(context)
    assert {:ok, reference} = Cargo.metadata(context.cargo, options)
    assert_receive {:cargo_spawn, worker, _spawn, _state}
    send(worker, {:finish, Adapter.terminal(), Jason.encode!(metadata_map(context)), ""})
    assert_receive {:rekindle_cargo_ready, ^reference}

    assert {:ok, _metadata} =
             Cargo.result(context.cargo, reference, context.web_authority)

    assert {:ok, changed, [{:cancel, 1}]} =
             Scheduler.change(context.web_scheduler, [:cargo_web], 1)

    assert :ok = Cargo.supersede(context.cargo, context.web_authority, changed)
  end

  test "supersession cancels obsolete work and rejects a late successful completion", context do
    options = base_options(context)
    assert {:ok, old_reference} = Cargo.metadata(context.cargo, options)
    assert_receive {:cargo_spawn, old_worker, _spawn, _state}

    assert {:ok, changed, [{:cancel, 1}]} =
             Scheduler.change(context.web_scheduler, [:cargo_web], 1)

    assert :ok = Cargo.supersede(context.cargo, context.web_authority, changed)
    assert_receive {:cargo_cancel, ^old_worker, %{"reason" => "obsolete"}}

    assert :ok = Cargo.supersede(context.cargo, context.web_authority, changed)
    refute_receive {:cargo_cancel, ^old_worker, _header}

    send(
      old_worker,
      {:finish_cancel, Adapter.terminal(), Jason.encode!(metadata_map(context)), ""}
    )

    assert_receive {:rekindle_cargo_ready, ^old_reference}

    assert {:error, %{code: :cancelled}} =
             Cargo.result(context.cargo, old_reference, context.web_authority)

    failure =
      Failure.new!(
        target: :web,
        stage: elem(Failure.stage_for(:cancelled), 1),
        code: :cancelled,
        message: "superseded"
      )

    assert {:ok, queued, _effects} = Scheduler.fail(changed, 1, failure, 1)
    assert {:ok, current, {:start, 2, [:cargo_web]}} = Scheduler.ready(queued, 1)

    current_identity = identity(:web, "revision-2")
    assert {:ok, current_authority} = Cargo.authorize(context.cargo, current_identity, current)
    current_options = Keyword.put(options, :authority, current_authority)

    assert {:ok, current_reference} = Cargo.metadata(context.cargo, current_options)
    assert_receive {:cargo_spawn, current_worker, _spawn, _state}

    send(
      current_worker,
      {:finish, Adapter.terminal(), Jason.encode!(metadata_map(context)), ""}
    )

    assert_receive {:rekindle_cargo_ready, ^current_reference}

    assert {:ok, _metadata} =
             Cargo.result(context.cargo, current_reference, current_authority)
  end

  test "supersession replay evidence has a fixed bound and rejects retired tokens", context do
    failure =
      Failure.new!(
        target: :web,
        stage: elem(Failure.stage_for(:cancelled), 1),
        code: :cancelled,
        message: "superseded"
      )

    {_scheduler, first, latest} =
      Enum.reduce(1..24, {context.web_scheduler, nil, nil}, fn revision,
                                                               {scheduler, first, _latest} ->
        identity = identity(:web, "revision-#{revision}")
        assert {:ok, authority} = Cargo.authorize(context.cargo, identity, scheduler)

        assert {:ok, changed, [{:cancel, ^revision}]} =
                 Scheduler.change(scheduler, [:cargo_web], revision)

        assert :ok = Cargo.supersede(context.cargo, authority, changed)
        assert :ok = Cargo.supersede(context.cargo, authority, changed)
        assert {:ok, queued, _effects} = Scheduler.fail(changed, revision, failure, revision)

        next_revision = revision + 1

        assert {:ok, current, {:start, ^next_revision, [:cargo_web]}} =
                 Scheduler.ready(queued, revision)

        {current, first || {authority, changed}, {authority, changed}}
      end)

    {first_authority, first_scheduler} = first
    {latest_authority, latest_scheduler} = latest
    state = :sys.get_state(context.cargo)
    assert length(state.supersessions) == 16
    assert map_size(state.authorities) == 0
    assert map_size(state.identities) == 0

    assert {:error, %{code: :cargo_protocol}} =
             Cargo.supersede(context.cargo, first_authority, first_scheduler)

    assert :ok = Cargo.supersede(context.cargo, latest_authority, latest_scheduler)
  end

  test "owner death cancels running jobs and releases their retained state", context do
    {owner, cargo, authority} = owned_cargo(context)
    options = Keyword.put(base_options(context), :authority, authority)

    assert {:ok, reference} = owner_call(owner, fn -> Cargo.metadata(cargo, options) end)
    assert_receive {:cargo_spawn, worker, _spawn, _state}
    Process.exit(owner, :kill)
    assert_receive {:cargo_cancel, ^worker, %{"reason" => "caller"}}

    send(
      worker,
      {:finish_cancel, Adapter.terminal(), Jason.encode!(metadata_map(context)), ""}
    )

    state =
      await_state(
        cargo,
        &(&1.jobs == %{} and &1.pool.cargo == %{} and &1.pool.helpers == MapSet.new())
      )

    refute state.owner_alive?
    assert state.completed == %{}
    assert state.authorities == %{}
    assert state.identities == %{}
    refute_receive {:owner_message, {:rekindle_cargo_ready, ^reference}}
  end

  test "owner death discards completed output and releases its capacity", context do
    {owner, cargo, authority} = owned_cargo(context)
    options = Keyword.put(base_options(context), :authority, authority)

    assert {:ok, reference} = owner_call(owner, fn -> Cargo.metadata(cargo, options) end)
    assert_receive {:cargo_spawn, worker, _spawn, _state}
    send(worker, {:finish, Adapter.terminal(), Jason.encode!(metadata_map(context)), ""})
    assert_receive {:owner_message, {:rekindle_cargo_ready, ^reference}}

    state = await_state(cargo, &(map_size(&1.completed) == 1))
    assert map_size(state.pool.cargo) == 1
    assert state.pool.helpers == MapSet.new()

    Process.exit(owner, :kill)
    state = await_state(cargo, &(!&1.owner_alive?))
    assert state.completed == %{}
    assert state.pool.cargo == %{}
    assert state.pool.helpers == MapSet.new()
    assert state.latest_revisions == %{}
    assert state.authorities == %{}
    assert state.identities == %{}
  end

  test "desktop uses the same facade and selects only compiler-artifact executable", context do
    config = desktop_config()

    options = target_options(context, :desktop, config)

    assert {:ok, metadata_reference} = Cargo.metadata(context.cargo, options)
    assert_receive {:cargo_spawn, worker, _spawn, _state}

    metadata_json =
      context
      |> metadata_map()
      |> put_in(["packages", Access.at(0), "targets", Access.at(0), "name"], "desktop")

    send(worker, {:finish, Adapter.terminal(), Jason.encode!(metadata_json), ""})
    assert_receive {:rekindle_cargo_ready, ^metadata_reference}
    assert {:ok, metadata} = Cargo.result(context.cargo, metadata_reference, options[:authority])

    executable = Path.join(context.target_directory, "debug/desktop")
    File.mkdir_p!(Path.dirname(executable))
    File.write!(executable, "native")
    File.chmod!(executable, 0o700)

    assert {:ok, build_reference} =
             Cargo.build(context.cargo, Keyword.put(options, :inventory, metadata.inventory))

    assert_receive {:cargo_spawn, build_worker, _spawn, _state}

    message =
      artifact_message(executable)
      |> put_in(["target", "name"], "desktop")
      |> Map.put("filenames", [Path.join(context.target_directory, "misleading.wasm")])
      |> Map.put("executable", executable)

    stdout =
      Jason.encode!(message) <>
        "\n" <> Jason.encode!(%{"reason" => "build-finished", "success" => true}) <> "\n"

    send(build_worker, {:finish, Adapter.terminal(), stdout, ""})
    assert_receive {:rekindle_cargo_ready, ^build_reference}
    assert {:ok, result} = Cargo.result(context.cargo, build_reference, options[:authority])
    assert result.artifact.path == executable
    assert Bitwise.band(result.artifact.mode, 0o100) != 0
  end

  test "canonical Cargo ownership has one facade and no target-local process implementation" do
    sources = Path.wildcard("lib/rekindle/**/*.ex")

    owners =
      Enum.filter(sources, fn path ->
        path |> File.read!() |> String.contains?("defmodule Rekindle.Cargo do")
      end)

    assert owners == ["lib/rekindle/cargo.ex"]

    for path <- Path.wildcard("lib/rekindle/cargo/**/*.ex") do
      source = File.read!(path)
      refute source =~ "System.cmd("
      refute source =~ "Port.open("
      refute source =~ ":os.cmd("
    end
  end

  defp base_options(context) do
    [
      target: :web,
      config: web_config(),
      client_root: context.client,
      project_root: context.root,
      mode: :dev,
      rust_target: "wasm32-unknown-unknown",
      authority: context.web_authority,
      target_directory: context.target_directory,
      process: process_policy()
    ]
  end

  defp target_options(context, :desktop, config) do
    identity = identity(:desktop)
    scheduler = scheduler(:desktop)
    assert {:ok, authority} = Cargo.authorize(context.cargo, identity, scheduler)

    base_options(context)
    |> Keyword.put(:target, :desktop)
    |> Keyword.put(:config, config)
    |> Keyword.put(:rust_target, "x86_64-unknown-linux-gnu")
    |> Keyword.put(:authority, authority)
  end

  defp identity(target, salt \\ "revision-1") do
    node = if target == :web, do: :cargo_web, else: :cargo_desktop
    binary = if target == :web, do: "web", else: "desktop"

    rust_target =
      if target == :web, do: "wasm32-unknown-unknown", else: "x86_64-unknown-linux-gnu"

    package = portable_package()

    model = %{
      "v" => 1,
      "node" => Atom.to_string(node),
      "target" => Atom.to_string(target),
      "package_identity" => package,
      "binary" => binary,
      "local_package_identities" => [package],
      "has_local_build_script" => false,
      "cargo_input_paths" => [],
      "source_roots" => ["client"]
    }

    config = %{
      "v" => 1,
      "node" => Atom.to_string(node),
      "target" => Atom.to_string(target),
      "fields" => %{
        "package_identity" => package,
        "binary" => binary,
        "rust_target" => rust_target,
        "profile" => "dev",
        "features" => [],
        "default_features" => true,
        "toolchain" => %{
          "kind" => "path",
          "declared_identity" => "test",
          "cargo_sha256" => @digest,
          "rustc_sha256" => @digest,
          "cargo_version" => "cargo 1.95.0",
          "rustc_vv" => "rustc 1.95.0",
          "rust_target" => rust_target
        },
        "environment_digest" => @digest
      }
    }

    direct_inputs = [
      %{"kind" => "value", "name" => "revision", "value_digest" => sha256(salt)}
    ]

    tools = [
      %{"name" => "cargo", "version" => "cargo 1.95.0", "content_digest" => nil},
      %{"name" => "rustc", "version" => "rustc 1.95.0", "content_digest" => nil}
    ]

    assert {:ok, identity} =
             Identity.node_key(
               node: node,
               target: target,
               profile: "dev",
               model_slice: model,
               config: config,
               direct_inputs: direct_inputs,
               tools: tools
             )

    identity
  end

  defp scheduler(target), do: scheduler(target, 1)

  defp scheduler(target, revision) when is_integer(revision) and revision > 0 do
    node = if target == :web, do: :cargo_web, else: :cargo_desktop
    assert {:ok, scheduler} = Scheduler.new(target, 0)
    assert {:ok, scheduler, []} = Scheduler.change(scheduler, [node], 0)
    assert {:ok, scheduler, {:start, 1, [^node]}} = Scheduler.ready(scheduler, 0)
    %{scheduler | latest_source_revision: revision, running_revision: revision}
  end

  defp owned_cargo(context) do
    test = self()
    owner = spawn(fn -> owner_loop(test) end)

    {:ok, cargo} =
      Cargo.start_link(
        runner: context.runner,
        helper: "/tmp/rekindle_toolchain",
        authority_owner: owner,
        max_cargo_builds: 2
      )

    on_exit(fn ->
      if Process.alive?(owner), do: Process.exit(owner, :kill)
      if Process.alive?(cargo), do: GenServer.stop(cargo)
    end)

    authority =
      owner_call(owner, fn ->
        Cargo.authorize(cargo, context.web_identity, context.web_scheduler)
      end)

    assert {:ok, authority} = authority
    {owner, cargo, authority}
  end

  defp owner_loop(test) do
    receive do
      {:call, caller, reference, callback} ->
        send(caller, {reference, callback.()})
        owner_loop(test)

      message ->
        send(test, {:owner_message, message})
        owner_loop(test)
    end
  end

  defp owner_call(owner, callback) do
    reference = make_ref()
    send(owner, {:call, self(), reference, callback})
    assert_receive {^reference, result}
    result
  end

  defp await_state(server, predicate, attempts \\ 100)

  defp await_state(server, predicate, attempts) when attempts > 0 do
    state = :sys.get_state(server)

    if predicate.(state) do
      state
    else
      Process.sleep(10)
      await_state(server, predicate, attempts - 1)
    end
  end

  defp await_state(server, _predicate, 0) do
    flunk("Cargo state did not settle: #{inspect(:sys.get_state(server))}")
  end

  defp portable_package do
    %{
      "kind" => "local",
      "manifest_path" => "client/Cargo.toml",
      "name" => "client",
      "version" => "0.1.0"
    }
  end

  defp web_config do
    %WebTarget{
      package: "client",
      binary: "web",
      backend: :canonical,
      features: [],
      profiles: %{dev: "dev", release: "release"},
      public: nil,
      hot_styles: [],
      projection: %{mode: :phoenix_static, root: "priv/static"},
      toolchain: %{kind: :path, cargo: "/usr/bin/true", rustc: "/usr/bin/true", identity: "test"},
      rust_target: "wasm32-unknown-unknown",
      default_features: true,
      environment: %EnvironmentPolicy{
        inherit: :none,
        set: [],
        unset: [],
        build_inputs: ["MODE"],
        redact: [],
        resolved: [{"MODE", "test"}]
      }
    }
  end

  defp desktop_config do
    %DesktopTarget{
      package: "client",
      binary: "desktop",
      backend: :canonical,
      features: [],
      profiles: %{dev: "dev", release: "release"},
      runtime: %{
        readiness: :ipc_v1,
        startup_timeout_ms: 5_000,
        startup_grace_ms: nil,
        shutdown_timeout_ms: 2_000,
        replacement: :overlap,
        handoff: :enabled
      },
      projection: %{mode: :directory, root: "dist/desktop"},
      toolchain: %{kind: :path, cargo: "/usr/bin/true", rustc: "/usr/bin/true", identity: "test"},
      rust_target: "x86_64-unknown-linux-gnu",
      default_features: true,
      environment: web_config().environment
    }
  end

  defp process_policy do
    %ProcessPolicy{
      build_timeout_ms: 5_000,
      terminate_grace_ms: 100,
      kill_grace_ms: 500,
      output_bytes_per_stream: 1_048_576,
      max_cargo_builds: 2,
      max_helper_jobs: 1
    }
  end

  defp metadata_map(context) do
    manifest = Path.join(context.client, "Cargo.toml")

    %{
      "workspace_root" => context.client,
      "target_directory" => context.target_directory,
      "workspace_members" => [@package_id],
      "packages" => [
        %{
          "id" => @package_id,
          "name" => "client",
          "version" => "0.1.0",
          "source" => nil,
          "manifest_path" => manifest,
          "features" => %{},
          "targets" => [
            %{
              "name" => "web",
              "kind" => ["bin"],
              "crate_types" => ["bin"],
              "src_path" => Path.join(context.client, "src/bin/web.rs")
            }
          ]
        }
      ],
      "resolve" => %{"nodes" => [%{"id" => @package_id, "dependencies" => []}]}
    }
  end

  defp artifact_message(path) do
    %{
      "reason" => "compiler-artifact",
      "package_id" => @package_id,
      "target" => %{"name" => "web", "kind" => ["bin"], "crate_types" => ["bin"]},
      "profile" => %{"test" => false},
      "features" => [],
      "filenames" => [path],
      "executable" => nil,
      "fresh" => false
    }
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
