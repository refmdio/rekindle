defmodule Rekindle.ArtifactStoreTest do
  use ExUnit.Case, async: false

  import Bitwise
  import ExUnit.CaptureLog

  alias Rekindle.{ArtifactStore, Shutdown}
  alias Rekindle.ArtifactStore.{Descriptor, Filesystem, Member}
  alias Rekindle.GenerationRef

  test "seals immutable content once and publishes independent generation identities" do
    root = state_root()
    {:ok, store} = start_store(root)

    {first, descriptor} = stage_web(store, "console.log('same')")
    refute File.exists?(artifact_path(root, :web, descriptor.artifact_id))
    assert {:ok, generation1} = ArtifactStore.seal(first, descriptor)

    {second, descriptor2} = stage_web(store, "console.log('same')", 2)
    assert %{descriptor2 | source_revision: 1} == descriptor
    assert {:ok, generation2} = ArtifactStore.seal(second, descriptor2)

    assert generation1.artifact_id == generation2.artifact_id
    refute generation1.generation_id == generation2.generation_id

    artifact = artifact_path(root, :web, descriptor.artifact_id)
    assert Enum.sort(File.ls!(artifact)) == ["members", "rekindle-web-manifest-v2.json"]
    assert Enum.sort(File.ls!(Path.join(artifact, "members"))) == ["entry.js"]
    assert mode(artifact) == 0o500
    assert mode(Path.join(artifact, "members")) == 0o500
    assert mode(Path.join(artifact, "members/entry.js")) == 0o400
    assert mode(Path.join(artifact, "rekindle-web-manifest-v2.json")) == 0o400
    assert :none = ArtifactStore.current(store, :web)

    assert :ok = ArtifactStore.activate(store, generation1, 1)
    assert {:ok, ^generation1} = ArtifactStore.current(store, :web)
    assert :none = ArtifactStore.fallback(store, :web)

    assert {:error, %{code: :artifact_missing}} =
             ArtifactStore.activate(store, generation2, 99)

    assert {:ok, ^generation1} = ArtifactStore.current(store, :web)

    assert :ok = ArtifactStore.activate(store, generation2, 2)
    assert {:ok, ^generation2} = ArtifactStore.current(store, :web)
    assert {:ok, ^generation1} = ArtifactStore.fallback(store, :web)

    pointer = read_json(Path.join(root, "current/web.json"))

    assert Map.keys(pointer) |> Enum.sort() ==
             ~w[artifact_id generation_id manifest_digest source_revision target v] |> Enum.sort()

    assert pointer["source_revision"] == 2
    assert pointer["generation_id"] == generation2.generation_id
  end

  test "activation errors preserve both prior pointers and a retry preserves the true fallback" do
    root = state_root()
    {:ok, store} = start_store(root)
    [first, second, third] = sealed_web_generations(store, ["first", "second", "third"])

    assert :ok = ArtifactStore.activate(store, first, 1)

    fallback_directory = Path.join(root, "fallback")
    File.chmod!(fallback_directory, 0o500)

    assert {:error, %{code: :io_failed}} = ArtifactStore.activate(store, second, 2)
    assert {:ok, ^first} = ArtifactStore.current(store, :web)
    assert :none = ArtifactStore.fallback(store, :web)

    File.chmod!(fallback_directory, 0o700)
    assert :ok = ArtifactStore.activate(store, second, 2)
    assert {:ok, ^second} = ArtifactStore.current(store, :web)
    assert {:ok, ^first} = ArtifactStore.fallback(store, :web)

    current_directory = Path.join(root, "current")
    File.chmod!(current_directory, 0o500)

    assert {:error, %{code: :io_failed}} = ArtifactStore.activate(store, third, 3)
    assert {:ok, ^second} = ArtifactStore.current(store, :web)
    assert {:ok, ^first} = ArtifactStore.fallback(store, :web)

    File.chmod!(current_directory, 0o700)
    assert :ok = ArtifactStore.activate(store, third, 3)
    assert {:ok, ^third} = ArtifactStore.current(store, :web)
    assert {:ok, ^second} = ArtifactStore.fallback(store, :web)
    assert File.ls!(Path.join(root, "activations")) == []
  end

  test "activation checkpoint errors obey the pointer commit boundary" do
    for checkpoint <- [
          :activation_journal_created,
          :activation_journal_written,
          :activation_journal_file_synced,
          :activation_journal_renamed,
          :activation_journal_directory_synced,
          :activation_journaled,
          :activation_fallback_created,
          :activation_fallback_written,
          :activation_fallback_file_synced,
          :activation_fallback_renamed,
          :activation_fallback_directory_synced,
          :activation_fallback_published,
          :activation_current_created,
          :activation_current_written,
          :activation_current_file_synced,
          :activation_current_renamed,
          :activation_current_directory_synced,
          :activation_current_published,
          :activation_journal_removed
        ] do
      root = state_root()
      {:ok, store} = start_store(root)

      [first, second, third] =
        sealed_web_generations(store, [
          "fallback-#{checkpoint}",
          "old-#{checkpoint}",
          "new-#{checkpoint}"
        ])

      assert :ok = ArtifactStore.activate(store, first, 1)
      assert :ok = ArtifactStore.activate(store, second, 2)

      result =
        ArtifactStore.activate(store, third, 3,
          checkpoint: fn
            ^checkpoint -> {:error, injected_activation_failure()}
            _other -> :ok
          end
        )

      if checkpoint in [
           :activation_journal_created,
           :activation_journal_written,
           :activation_journal_file_synced,
           :activation_journal_renamed,
           :activation_journal_directory_synced,
           :activation_journaled,
           :activation_fallback_created,
           :activation_fallback_written,
           :activation_fallback_file_synced,
           :activation_fallback_renamed,
           :activation_fallback_directory_synced,
           :activation_fallback_published,
           :activation_current_created,
           :activation_current_written,
           :activation_current_file_synced
         ] do
        assert {:error, %{code: :io_failed}} = result
        assert {:ok, ^second} = ArtifactStore.current(store, :web)
        assert {:ok, ^first} = ArtifactStore.fallback(store, :web)
      else
        assert :ok = result
        assert {:ok, ^third} = ArtifactStore.current(store, :web)
        assert {:ok, ^second} = ArtifactStore.fallback(store, :web)
      end

      assert File.ls!(Path.join(root, "activations")) == []
      assert Enum.sort(File.ls!(Path.join(root, "current"))) == ["web.json"]
      assert Enum.sort(File.ls!(Path.join(root, "fallback"))) == ["web.json"]

      assert :ok = ArtifactStore.activate(store, third, 3)
      assert {:ok, ^third} = ArtifactStore.current(store, :web)
      assert {:ok, ^second} = ArtifactStore.fallback(store, :web)
    end
  end

  test "recovers activation crashes on both sides of the pointer commit boundary" do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    for checkpoint <- [
          :activation_journal_created,
          :activation_journal_written,
          :activation_journal_file_synced,
          :activation_journal_renamed,
          :activation_journal_directory_synced,
          :activation_journaled,
          :activation_fallback_created,
          :activation_fallback_written,
          :activation_fallback_file_synced,
          :activation_fallback_renamed,
          :activation_fallback_directory_synced,
          :activation_fallback_published,
          :activation_current_created,
          :activation_current_written,
          :activation_current_file_synced,
          :activation_current_renamed,
          :activation_current_directory_synced,
          :activation_current_published,
          :activation_journal_removed
        ] do
      root = state_root()
      {:ok, store} = start_store(root)

      [first, second, third] =
        sealed_web_generations(store, [
          "fallback-#{checkpoint}",
          "old-#{checkpoint}",
          "new-#{checkpoint}"
        ])

      assert :ok = ArtifactStore.activate(store, first, 1)
      assert :ok = ArtifactStore.activate(store, second, 2)

      assert capture_log(fn ->
               assert catch_exit(
                        ArtifactStore.activate(store, third, 3,
                          checkpoint: fn
                            ^checkpoint -> exit(:injected_activation_crash)
                            _other -> :ok
                          end
                        )
                      )

               assert_receive {:EXIT, ^store, :injected_activation_crash}
             end) =~ "injected_activation_crash"

      {:ok, recovered} = start_store(root)

      if checkpoint in [
           :activation_journal_created,
           :activation_journal_written,
           :activation_journal_file_synced,
           :activation_journal_renamed,
           :activation_journal_directory_synced,
           :activation_journaled,
           :activation_fallback_created,
           :activation_fallback_written,
           :activation_fallback_file_synced,
           :activation_fallback_renamed,
           :activation_fallback_directory_synced,
           :activation_fallback_published,
           :activation_current_created,
           :activation_current_written,
           :activation_current_file_synced
         ] do
        assert {:ok, ^second} = ArtifactStore.current(recovered, :web)
        assert {:ok, ^first} = ArtifactStore.fallback(recovered, :web)
      else
        assert {:ok, ^third} = ArtifactStore.current(recovered, :web)
        assert {:ok, ^second} = ArtifactStore.fallback(recovered, :web)
      end

      assert File.ls!(Path.join(root, "activations")) == []
      assert Enum.sort(File.ls!(Path.join(root, "current"))) == ["web.json"]
      assert Enum.sort(File.ls!(Path.join(root, "fallback"))) == ["web.json"]

      assert :ok = ArtifactStore.activate(recovered, third, 3)
      assert {:ok, ^third} = ArtifactStore.current(recovered, :web)
      assert {:ok, ^second} = ArtifactStore.fallback(recovered, :web)
    end
  end

  test "quarantines foreign activation temporaries without changing prior state" do
    for {kind, directory} <- [journal: "activations", current: "current", fallback: "fallback"] do
      root = state_root()
      {:ok, store} = start_store(root)
      [generation] = sealed_web_generations(store, ["preserved-#{kind}"])
      assert :ok = ArtifactStore.activate(store, generation, 1)
      :ok = GenServer.stop(store)

      current_path = Path.join(root, "current/web.json")
      current_before = File.read!(current_path)

      temporary =
        Path.join([
          root,
          directory,
          ".rekindle-activation-v1-#{kind}-web-#{String.duplicate("0", 32)}-#{String.duplicate("0", 64)}.tmp"
        ])

      File.write!(temporary, "foreign")
      File.chmod!(temporary, 0o600)

      {:ok, recovered} = start_store(root)
      assert File.exists?(Path.join(root, "quarantine-v1.json"))
      assert File.read!(current_path) == current_before
      assert File.read!(temporary) == "foreign"
      assert_generation_preserved(root, generation)

      assert {:error, %{code: :cleanup_unconfirmed}} =
               ArtifactStore.allocate(recovered, :web)

      :ok = GenServer.stop(recovered)
    end
  end

  test "quarantines multiple owned activation temporaries without removing either" do
    root = state_root()
    {:ok, store} = start_store(root)
    [generation] = sealed_web_generations(store, ["preserved-ambiguous-temporaries"])
    assert :ok = ArtifactStore.activate(store, generation, 1)
    :ok = GenServer.stop(store)

    current_path = Path.join(root, "current/web.json")
    current_before = File.read!(current_path)

    temporaries =
      for transaction_id <- [String.duplicate("1", 32), String.duplicate("2", 32)] do
        Path.join(
          root,
          "activations/.rekindle-activation-v1-journal-web-#{transaction_id}-#{String.duplicate("0", 64)}.tmp"
        )
      end

    Enum.each(temporaries, fn temporary ->
      File.write!(temporary, "")
      File.chmod!(temporary, 0o600)
    end)

    {:ok, recovered} = start_store(root)
    assert File.exists?(Path.join(root, "quarantine-v1.json"))
    assert File.read!(current_path) == current_before
    assert Enum.all?(temporaries, &File.exists?/1)
    assert_generation_preserved(root, generation)

    assert {:error, %{code: :cleanup_unconfirmed}} =
             ArtifactStore.allocate(recovered, :web)
  end

  test "rejects self-consistent artifact identity forgeries and identity field mutations" do
    web_mutations = [
      fn manifest -> put_in(manifest, ["build", "build_key"], String.duplicate("1", 64)) end,
      fn manifest -> put_in(manifest, ["members", Access.at(0), "path"], "other.js") end,
      fn manifest -> put_in(manifest, ["members", Access.at(0), "role"], "asset") end,
      fn manifest ->
        put_in(manifest, ["members", Access.at(0), "sha256"], String.duplicate("2", 64))
      end,
      fn manifest -> put_in(manifest, ["members", Access.at(0), "size"], 999) end,
      fn manifest -> Map.put(manifest, "artifact_id", wrong_artifact_id(:web, manifest)) end
    ]

    desktop_mutations = [
      fn manifest -> put_in(manifest, ["build", "build_key"], String.duplicate("1", 64)) end,
      fn manifest -> put_in(manifest, ["executable", "path"], "other") end,
      fn manifest ->
        put_in(manifest, ["executable", "sha256"], String.duplicate("2", 64))
      end,
      fn manifest -> put_in(manifest, ["executable", "size"], 999) end,
      fn manifest -> put_in(manifest, ["executable", "mode"], "regular") end,
      fn manifest -> Map.put(manifest, "artifact_id", wrong_artifact_id(:desktop, manifest)) end
    ]

    for {target, mutations} <- [web: web_mutations, desktop: desktop_mutations],
        mutation <- mutations do
      root = state_root()
      {:ok, store} = start_store(root)

      {staging, descriptor} =
        if target == :web,
          do: stage_web(store, "identity-mutation"),
          else: stage_sparse_desktop(store, 1, 8)

      manifest_path = Path.join(staging.path, descriptor.manifest_path)
      manifest = manifest_path |> File.read!() |> Jason.decode!() |> mutation.()
      artifact_id = manifest["artifact_id"]
      manifest = Map.delete(manifest, "manifest_digest")
      digest = manifest_digest(target, manifest)
      manifest = Map.put(manifest, "manifest_digest", digest)
      File.write!(manifest_path, Rekindle.CanonicalValue.encode!(manifest))

      descriptor = %{descriptor | artifact_id: artifact_id, manifest_digest: digest}

      assert {:error, %{code: :manifest_invalid}} = ArtifactStore.seal(staging, descriptor)
      refute File.exists?(artifact_path(root, target, artifact_id))
    end
  end

  test "rejects escaping, aliased, extra, changed, linked, and special members" do
    for mutation <- [
          :traversal,
          :noncanonical_unicode,
          :control_character,
          :collision,
          :extra,
          :digest,
          :manifest,
          :symlink,
          :hard_link
        ] do
      root = state_root()
      {:ok, store} = start_store(root)
      {staging, descriptor} = stage_web(store, "entry")

      descriptor =
        case mutation do
          :traversal ->
            %{descriptor | members: [%{hd(descriptor.members) | path: "../entry.js"}]}

          :noncanonical_unicode ->
            %{descriptor | members: [%{hd(descriptor.members) | path: "members/café.js"}]}

          :control_character ->
            %{descriptor | members: [%{hd(descriptor.members) | path: "members/app\n.js"}]}

          :collision ->
            member = hd(descriptor.members)
            other = %{member | path: "members/ENTRY.js"}
            %{descriptor | members: [member, other]}

          :extra ->
            File.write!(Path.join(staging.path, "extra"), "foreign")
            descriptor

          :digest ->
            %{
              descriptor
              | members: [%{hd(descriptor.members) | sha256: String.duplicate("0", 64)}]
            }

          :manifest ->
            path = Path.join(staging.path, descriptor.manifest_path)
            changed = path |> File.read!() |> Jason.decode!() |> Map.put("changed", true)
            File.write!(path, Rekindle.CanonicalValue.encode!(changed))
            descriptor

          :symlink ->
            File.rm!(Path.join(staging.path, "members/entry.js"))

            File.ln_s!(
              "../rekindle-web-manifest-v2.json",
              Path.join(staging.path, "members/entry.js")
            )

            descriptor

          :hard_link ->
            source = Path.join(staging.path, "members/entry.js")
            File.ln!(source, Path.join(staging.path, "linked"))
            descriptor
        end

      assert {:error, %{code: code}} = ArtifactStore.seal(staging, descriptor)
      assert code in [:manifest_invalid, :artifact_changed]
      refute File.exists?(artifact_path(root, :web, descriptor.artifact_id))
    end
  end

  test "serializes concurrent publication without duplicating immutable content" do
    root = state_root()
    {:ok, store} = start_store(root)
    parent = self()

    tasks =
      for _index <- 1..2 do
        Task.async(fn ->
          {staging, descriptor} = stage_web(store, "concurrent")
          send(parent, {:ready, self()})

          receive do
            :publish -> ArtifactStore.seal(staging, descriptor)
          end
        end)
      end

    pids =
      for _index <- 1..2 do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :publish))

    generations =
      Enum.map(tasks, fn task ->
        {:ok, value} = Task.await(task)
        value
      end)

    assert length(Enum.uniq_by(generations, & &1.generation_id)) == 2
    assert length(Enum.uniq_by(generations, & &1.artifact_id)) == 1

    [artifact_id] = Enum.map(generations, & &1.artifact_id) |> Enum.uniq()
    assert File.dir?(artifact_path(root, :web, artifact_id))
  end

  test "leases, current, and fallback records protect collection" do
    root = state_root()
    {:ok, store} = start_store(root, retained_generations: 1)

    generations =
      for {content, revision} <- Enum.with_index(["one", "two", "three", "four"], 1) do
        {staging, descriptor} = stage_web(store, content, revision)
        {:ok, generation} = ArtifactStore.seal(staging, descriptor)
        generation
      end

    [first, _second, third, fourth] = generations
    assert :ok = ArtifactStore.activate(store, third, 3)
    assert :ok = ArtifactStore.activate(store, fourth, 4)
    assert {:ok, lease} = ArtifactStore.acquire(store, first)
    assert ArtifactStore.valid_lease?(lease)

    assert {:ok, %{removed_generations: 0}} = ArtifactStore.collect(store)
    assert File.dir?(artifact_path(root, :web, first.artifact_id))

    assert :ok = ArtifactStore.release(lease)
    refute ArtifactStore.valid_lease?(lease)
    assert {:ok, %{removed_generations: 1}} = ArtifactStore.collect(store)
    refute File.exists?(artifact_path(root, :web, first.artifact_id))
    assert File.dir?(artifact_path(root, :web, third.artifact_id))
    assert File.dir?(artifact_path(root, :web, fourth.artifact_id))
  end

  test "pointer reads quarantine malformed and unreadable current or fallback state" do
    for kind <- [:current, :fallback], mutation <- [:malformed, :unreadable] do
      root = state_root()
      {:ok, store} = start_store(root)
      [first, second] = sealed_web_generations(store, ["read-first", "read-second"])
      assert :ok = ArtifactStore.activate(store, first, 1)
      assert :ok = ArtifactStore.activate(store, second, 2)

      corrupt_pointer(root, kind, mutation)

      result =
        case kind do
          :current -> ArtifactStore.current(store, :web)
          :fallback -> ArtifactStore.fallback(store, :web)
        end

      assert {:error, %{code: :cache_corrupt}} = result
      assert_generation_preserved(root, first)
      assert_generation_preserved(root, second)

      assert {:error, %{code: :cleanup_unconfirmed}} =
               ArtifactStore.allocate(store, :web)

      :ok = GenServer.stop(store)
    end
  end

  test "rejects untrusted persistent record nodes without consuming them" do
    cases = [
      pointer: :symlink,
      reference: :hard_link,
      seal: :unsafe_mode,
      activation: :directory,
      deletion: :fifo,
      attempt: :symlink
    ]

    for {kind, mutation} <- cases do
      root = state_root()
      path = persistent_record_fixture(root, kind)
      external = substitute_private_record(root, path, mutation)
      node_before = private_node_state(path)
      external_before = if external, do: File.read!(external)

      {:ok, recovered} = start_store(root)
      assert private_node_state(path) == node_before
      if external, do: assert(File.read!(external) == external_before)
      assert File.regular?(Path.join(root, "quarantine-v1.json"))
      assert {:error, %{code: :cleanup_unconfirmed}} = ArtifactStore.allocate(recovered, :web)
      :ok = GenServer.stop(recovered)
    end
  end

  test "quarantines an untrusted project identity without consuming it" do
    for mutation <- [:symlink, :hard_link, :unsafe_mode, :directory, :fifo] do
      root = state_root()
      {:ok, store} = start_store(root)
      :ok = GenServer.stop(store)

      path = Path.join(root, "project-id")
      external = substitute_private_record(root, path, mutation)
      node_before = private_node_state(path)
      external_before = if external, do: File.read!(external)

      {:ok, recovered} = start_store(root)
      assert private_node_state(path) == node_before
      if external, do: assert(File.read!(external) == external_before)
      assert File.regular?(Path.join(root, "quarantine-v1.json"))
      assert {:error, %{code: :cleanup_unconfirmed}} = ArtifactStore.allocate(recovered, :web)
      :ok = GenServer.stop(recovered)
    end
  end

  test "pointer corruption stops every artifact mutation before disk state changes" do
    for operation <- [:allocate, :seal, :activate, :collect],
        kind <- [:current, :fallback],
        mutation <- [:malformed, :unreadable] do
      root = state_root()
      {:ok, store} = start_store(root, retained_generations: 1)

      [first, second, third] =
        sealed_web_generations(store, [
          "#{operation}-first",
          "#{operation}-second",
          "#{operation}-third"
        ])

      assert :ok = ArtifactStore.activate(store, first, 1)
      assert :ok = ArtifactStore.activate(store, second, 2)

      pending =
        if operation == :seal,
          do: stage_web(store, "#{operation}-pending", 4),
          else: nil

      staging_before = File.ls!(Path.join(root, "staging")) |> Enum.sort()
      corrupt_pointer(root, kind, mutation)

      result =
        case operation do
          :allocate ->
            ArtifactStore.allocate(store, :web)

          :seal ->
            pending
            |> then(fn {staging, descriptor} -> ArtifactStore.seal(staging, descriptor) end)

          :activate ->
            ArtifactStore.activate(store, third, 3)

          :collect ->
            ArtifactStore.collect(store)
        end

      assert {:error, %{code: :cache_corrupt}} = result

      for generation <- [first, second, third] do
        assert_generation_preserved(root, generation)
      end

      assert File.ls!(Path.join(root, "staging")) |> Enum.sort() == staging_before
      assert File.ls!(Path.join(root, "activations")) == []
      assert File.ls!(Path.join(root, "deletions")) == []

      assert {:error, %{code: :cleanup_unconfirmed}} =
               ArtifactStore.allocate(store, :web)

      :ok = GenServer.stop(store)
    end
  end

  test "lease release rejects non-owners and accepts an explicit release authority" do
    root = state_root()
    {:ok, store} = start_store(root)
    {staging, descriptor} = stage_web(store, "delegated-release")
    {:ok, generation} = ArtifactStore.seal(staging, descriptor)
    {:ok, lease} = ArtifactStore.acquire(store, generation)

    assert {:ok, sealed_descriptor} = ArtifactStore.sealed_descriptor(lease)
    assert sealed_descriptor.artifact_id == generation.artifact_id
    assert sealed_descriptor.members == descriptor.members

    authorize_task = Task.async(fn -> ArtifactStore.authorize_release(lease) end)
    release_task = Task.async(fn -> ArtifactStore.release(lease) end)
    descriptor_task = Task.async(fn -> ArtifactStore.sealed_descriptor(lease) end)

    assert {:error, %{code: :contract_violation}} = Task.await(authorize_task)
    assert {:error, %{code: :contract_violation}} = Task.await(release_task)
    assert {:error, %{code: :contract_violation}} = Task.await(descriptor_task)
    assert ArtifactStore.valid_lease?(lease)
    assert {:ok, authority} = ArtifactStore.authorize_release(lease)

    task = Task.async(fn -> ArtifactStore.release(authority) end)

    assert :ok = Task.await(task)
    refute ArtifactStore.valid_lease?(lease)
    assert {:error, %{code: :contract_violation}} = ArtifactStore.release(authority)
  end

  test "shutdown releases a real artifact lease before collection" do
    root = state_root()
    {:ok, store} = start_store(root, retained_generations: 1)

    {first_staging, first_descriptor} = stage_web(store, "shutdown-release", 1)
    {:ok, first} = ArtifactStore.seal(first_staging, first_descriptor)
    {second_staging, second_descriptor} = stage_web(store, "retained", 2)
    {:ok, _second} = ArtifactStore.seal(second_staging, second_descriptor)

    {:ok, lease} = ArtifactStore.acquire(store, first)
    coordinator = start_supervised!({Shutdown, []})
    assert {:ok, _reference} = Shutdown.track_lease(coordinator, lease)
    assert ArtifactStore.valid_lease?(lease)

    assert %Shutdown.Result{status: :clean, failures: []} = Shutdown.shutdown(coordinator)
    refute ArtifactStore.valid_lease?(lease)
    assert {:ok, %{removed_generations: 1}} = ArtifactStore.collect(store)
    refute File.exists?(artifact_path(root, :web, first.artifact_id))
  end

  test "sealed descriptor access revalidates immutable member content" do
    root = state_root()
    {:ok, store} = start_store(root)
    {staging, descriptor} = stage_web(store, "verified-descriptor")
    {:ok, generation} = ArtifactStore.seal(staging, descriptor)
    {:ok, lease} = ArtifactStore.acquire(store, generation)
    member = Path.join(artifact_path(root, :web, generation.artifact_id), "members/entry.js")

    File.chmod!(member, 0o600)
    File.write!(member, "changed")

    assert {:error, %{code: :artifact_changed}} = ArtifactStore.sealed_descriptor(lease)
    assert ArtifactStore.valid_lease?(lease)
    assert :ok = ArtifactStore.release(lease)
  end

  test "collection enforces the configured byte bound independently of count" do
    root = state_root()
    {:ok, store} = start_store(root, retained_generations: 20, max_generation_bytes: 67_108_864)

    generations =
      for marker <- [1, 2] do
        {staging, descriptor} = stage_sparse_desktop(store, marker, 35_000_000)
        {:ok, generation} = ArtifactStore.seal(staging, descriptor)
        generation
      end

    assert {:ok, %{removed_generations: 1, retained_bytes: retained}} =
             ArtifactStore.collect(store)

    assert retained < 67_108_864
    assert Enum.count(generations, &File.dir?(artifact_path(root, :desktop, &1.artifact_id))) == 1
  end

  test "recovers collection at every durable deletion boundary" do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    for checkpoint <- [:deletion_journaled, :reference_deleted, :artifact_deleted] do
      root = state_root()
      {:ok, store} = start_store(root, retained_generations: 1)
      {first_stage, first_descriptor} = stage_web(store, "delete-first", 1)
      {:ok, first} = ArtifactStore.seal(first_stage, first_descriptor)
      {second_stage, second_descriptor} = stage_web(store, "keep-second", 2)
      {:ok, second} = ArtifactStore.seal(second_stage, second_descriptor)

      assert capture_log(fn ->
               assert catch_exit(
                        ArtifactStore.collect(store, [],
                          checkpoint: fn
                            ^checkpoint -> exit(:injected_collection_crash)
                            _other -> :ok
                          end
                        )
                      )

               assert_receive {:EXIT, ^store, :injected_collection_crash}
             end) =~ "injected_collection_crash"

      {:ok, recovered} = start_store(root, retained_generations: 1)
      refute File.exists?(artifact_path(root, :web, first.artifact_id))
      assert File.dir?(artifact_path(root, :web, second.artifact_id))
      assert File.ls!(Path.join(root, "deletions")) == []
      assert {:ok, %{removed_generations: 0}} = ArtifactStore.collect(recovered)
    end
  end

  test "deletion recovery preserves all artifacts when pointer state is ambiguous" do
    for kind <- [:current, :fallback], mutation <- [:malformed, :unreadable] do
      root = state_root()
      {:ok, store} = start_store(root, retained_generations: 1)
      [first, second] = sealed_web_generations(store, ["pending-delete", "retained"])
      :ok = GenServer.stop(store)

      journal = %{
        "v" => 1,
        "target" => "web",
        "generation_id" => first.generation_id,
        "artifact_id" => first.artifact_id
      }

      journal_path = Path.join(root, "deletions/#{first.generation_id}.json")
      assert :ok = Filesystem.atomic_write(journal_path, journal, :deletion_journal)
      corrupt_pointer(root, kind, mutation)

      {:ok, recovered} = start_store(root, retained_generations: 1)
      assert File.exists?(Path.join(root, "quarantine-v1.json"))
      assert File.regular?(journal_path)
      assert_generation_preserved(root, first)
      assert_generation_preserved(root, second)

      assert {:error, %{code: :cleanup_unconfirmed}} =
               ArtifactStore.allocate(recovered, :web)

      :ok = GenServer.stop(recovered)
    end
  end

  test "recovers a renamed artifact after crashes at durable publication boundaries" do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    for checkpoint <- [:publication_staged, :publication_sealed, :renamed, :metadata_published] do
      root = state_root()
      {:ok, store} = start_store(root)
      {staging, descriptor} = stage_web(store, Atom.to_string(checkpoint))

      assert capture_log(fn ->
               assert catch_exit(
                        ArtifactStore.seal(staging, descriptor,
                          checkpoint: fn
                            ^checkpoint -> exit(:injected_publication_crash)
                            _other -> :ok
                          end
                        )
                      )

               assert_receive {:EXIT, ^store, :injected_publication_crash}
             end) =~ "injected_publication_crash"

      {:ok, recovered} = start_store(root)

      generation = generation(staging, descriptor)
      assert {:ok, lease} = ArtifactStore.acquire(recovered, generation)
      assert ArtifactStore.valid_lease?(lease)
      assert :ok = ArtifactStore.release(lease)
      refute File.exists?(Path.dirname(staging.path))
    end
  end

  test "removes proven incomplete staging after a pre-rename crash" do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    root = state_root()
    {:ok, store} = start_store(root)
    {staging, descriptor} = stage_web(store, "pre-rename")

    assert capture_log(fn ->
             assert catch_exit(
                      ArtifactStore.seal(staging, descriptor,
                        checkpoint: fn
                          :sealed -> exit(:injected_publication_crash)
                          _other -> :ok
                        end
                      )
                    )

             assert_receive {:EXIT, ^store, :injected_publication_crash}
           end) =~ "injected_publication_crash"

    {:ok, recovered} = start_store(root)
    refute File.exists?(Path.dirname(staging.path))
    refute File.exists?(artifact_path(root, :web, descriptor.artifact_id))

    assert {:error, %{code: :artifact_missing}} =
             ArtifactStore.acquire(recovered, generation(staging, descriptor))
  end

  test "does not expose a candidate before its rename linearization point" do
    root = state_root()
    {:ok, store} = start_store(root)
    parent = self()

    task =
      Task.async(fn ->
        {staging, descriptor} = stage_web(store, "blocked")

        result =
          ArtifactStore.seal(staging, descriptor,
            checkpoint: fn
              :sealed ->
                send(parent, {
                  :sealed_not_renamed,
                  descriptor.artifact_id,
                  mode(Path.dirname(staging.path)),
                  mode(Path.join(root, "generations/web"))
                })

                receive do
                  :continue -> :ok
                end

              _other ->
                :ok
            end
          )

        {result, descriptor.artifact_id}
      end)

    assert_receive {:sealed_not_renamed, artifact_id, source_parent_mode, target_parent_mode},
                   5_000

    assert source_parent_mode == 0o700
    assert target_parent_mode == 0o700
    refute File.exists?(artifact_path(root, :web, artifact_id))
    send(store, :continue)
    assert {{:ok, _generation}, ^artifact_id} = Task.await(task)
    assert File.dir?(artifact_path(root, :web, artifact_id))
  end

  test "quarantines changed sealed state instead of guessing a replacement" do
    root = state_root()
    {:ok, store} = start_store(root)
    {staging, descriptor} = stage_web(store, "original")
    {:ok, generation} = ArtifactStore.seal(staging, descriptor)
    assert :ok = ArtifactStore.activate(store, generation, 1)
    :ok = GenServer.stop(store)

    member = Path.join(artifact_path(root, :web, descriptor.artifact_id), "members/entry.js")
    :ok = File.chmod(member, 0o600)
    :ok = File.write(member, "changed")

    {:ok, quarantined} = start_store(root)
    assert File.exists?(Path.join(root, "quarantine-v1.json"))
    assert {:error, %{code: :cleanup_unconfirmed}} = ArtifactStore.current(quarantined, :web)

    assert {:error, %{code: :cleanup_unconfirmed}} =
             ArtifactStore.allocate(quarantined, :web)
  end

  test "retains valid inactive generations across restart without guessing current" do
    root = state_root()
    {:ok, store} = start_store(root)
    project_id = File.read!(Path.join(root, "project-id"))
    {staging, descriptor} = stage_web(store, "retained", 7)
    {:ok, generation} = ArtifactStore.seal(staging, descriptor)
    :ok = GenServer.stop(store)

    {:ok, recovered} = start_store(root)
    assert File.read!(Path.join(root, "project-id")) == project_id
    assert :none = ArtifactStore.current(recovered, :web)
    assert {:ok, lease} = ArtifactStore.acquire(recovered, generation)
    assert :ok = ArtifactStore.release(lease)
  end

  test "quarantines unknown generation-store children" do
    root = state_root()
    {:ok, store} = start_store(root)
    :ok = GenServer.stop(store)
    File.write!(Path.join(root, "generations/web/foreign"), "unknown")

    {:ok, recovered} = start_store(root)
    assert File.exists?(Path.join(root, "quarantine-v1.json"))

    assert {:error, %{code: :cleanup_unconfirmed}} =
             ArtifactStore.allocate(recovered, :web)
  end

  test "quarantines unknown artifact-store root nodes without consuming them" do
    for kind <- [:regular, :directory, :symlink, :fifo] do
      root = state_root()
      {:ok, store} = start_store(root)
      :ok = GenServer.stop(store)

      path = Path.join(root, "unknown-state")
      unknown_root_node!(path, kind)
      node_before = private_node_state(path)

      {:ok, recovered} = start_store(root)
      assert private_node_state(path) == node_before
      assert File.regular?(Path.join(root, "quarantine-v1.json"))
      assert {:error, %{code: :cleanup_unconfirmed}} = ArtifactStore.allocate(recovered, :web)
      :ok = GenServer.stop(recovered)
    end
  end

  test "quarantined state is not available to runtime consumers" do
    root = state_root()
    {:ok, store} = start_store(root)
    [first, second] = sealed_web_generations(store, ["quarantine-old", "quarantine-new"])
    assert :ok = ArtifactStore.activate(store, first, 1)
    assert :ok = ArtifactStore.activate(store, second, 2)
    :ok = GenServer.stop(store)
    unknown_root_node!(Path.join(root, "unknown-state"), :regular)

    {:ok, quarantined} = start_store(root)

    for result <- [
          ArtifactStore.current(quarantined, :web),
          ArtifactStore.fallback(quarantined, :web),
          ArtifactStore.acquire(quarantined, first),
          ArtifactStore.acquire(quarantined, second)
        ] do
      assert {:error, %{code: :cleanup_unconfirmed}} = result
    end

    :ok = GenServer.stop(quarantined)
  end

  test "quarantine invalidates lease consumption but still permits release" do
    root = state_root()
    {:ok, store} = start_store(root)
    [generation] = sealed_web_generations(store, ["leased-before-quarantine"])
    assert :ok = ArtifactStore.activate(store, generation, 1)
    assert {:ok, lease} = ArtifactStore.acquire(store, generation)
    corrupt_pointer(root, :current, :malformed)

    assert {:error, %{code: :cache_corrupt}} = ArtifactStore.current(store, :web)
    refute ArtifactStore.valid_lease?(lease)
    assert {:error, %{code: :cleanup_unconfirmed}} = ArtifactStore.sealed_descriptor(lease)
    assert {:error, %{code: :cleanup_unconfirmed}} = ArtifactStore.authorize_release(lease)
    assert :ok = ArtifactStore.release(lease)
  end

  test "owner death removes only its marked incomplete staging" do
    root = state_root()
    {:ok, store} = start_store(root)
    parent = self()

    owner =
      spawn(fn ->
        {:ok, staging} = ArtifactStore.allocate(store, :web)
        send(parent, {:allocated, staging.path})
      end)

    monitor = Process.monitor(owner)
    assert_receive {:allocated, path}
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    eventually(fn -> refute File.exists?(Path.dirname(path)) end)
  end

  test "preserves project identity while recovering attempt allocation at every state write boundary" do
    for boundary <- state_write_boundaries() do
      root = state_root()
      {:ok, store} = start_store(root)
      :ok = GenServer.stop(store)

      project_id_path = Path.join(root, "project-id")
      project_id = File.read!(project_id_path)

      attempt_id = Filesystem.random_id()
      attempt_path = Path.join([root, "staging", attempt_id])
      body = Path.join(attempt_path, "body")
      File.mkdir!(attempt_path)
      File.chmod!(attempt_path, 0o700)
      File.mkdir!(body)
      File.chmod!(body, 0o700)

      marker = %{
        "v" => 1,
        "attempt_id" => attempt_id,
        "generation_id" => Filesystem.random_id(),
        "session_id" => Filesystem.random_id(),
        "target" => "web",
        "owner" => inspect(self())
      }

      crash_state_write(
        Path.join(attempt_path, "attempt-v1.json"),
        marker,
        :attempt_marker,
        boundary
      )

      {:ok, recovered} = start_store(root)
      assert File.read!(project_id_path) == project_id
      refute File.exists?(attempt_path)
      assert state_temporaries(root) == []
      assert {:ok, _staging} = ArtifactStore.allocate(recovered, :web)
      :ok = GenServer.stop(recovered)
    end
  end

  test "recovers first-start project identity writes at every state write boundary" do
    for boundary <- state_write_boundaries() do
      root = state_root()
      File.mkdir!(root)
      File.chmod!(root, 0o700)
      intended = Filesystem.random_id()

      crash_state_write(Path.join(root, "project-id"), intended, :project_id, boundary)

      {:ok, store} = start_store(root)
      project_id = File.read!(Path.join(root, "project-id"))
      assert Regex.match?(~r/\A[0-9a-f]{32}\z/, project_id)

      if boundary == :created,
        do: refute(project_id == intended),
        else: assert(project_id == intended)

      assert state_temporaries(root) == []
      assert {:ok, _staging} = ArtifactStore.allocate(store, :web)
      :ok = GenServer.stop(store)
    end
  end

  test "preserves missing project identity ambiguity in a nonempty store" do
    for state <- [:sealed, :pointers], temporary_payload <- [:empty, :filled] do
      root = state_root()
      {:ok, store} = start_store(root)
      [first, second] = sealed_web_generations(store, ["identity-old", "identity-new"])

      if state == :pointers do
        assert :ok = ArtifactStore.activate(store, first, 1)
        assert :ok = ArtifactStore.activate(store, second, 2)
      end

      :ok = GenServer.stop(store)
      old_project_id = File.read!(Path.join(root, "project-id"))
      File.rm!(Path.join(root, "project-id"))
      durable_before = project_identity_state(root, [first, second])

      intended =
        if old_project_id == String.duplicate("a", 32),
          do: String.duplicate("b", 32),
          else: String.duplicate("a", 32)

      name =
        Filesystem.state_temporary_name(
          :project_id,
          "project-id",
          Filesystem.sha256_bytes(intended),
          "00000000000000000000000000000000"
        )

      temporary = Path.join(root, name)
      contents = if temporary_payload == :empty, do: "", else: intended
      File.write!(temporary, contents)
      File.chmod!(temporary, 0o600)

      {:ok, recovered} = start_store(root)
      refute File.exists?(Path.join(root, "project-id"))
      assert File.read!(temporary) == contents
      assert project_identity_state(root, [first, second]) == durable_before
      assert File.regular?(Path.join(root, "quarantine-v1.json"))
      assert {:error, %{code: :cleanup_unconfirmed}} = ArtifactStore.allocate(recovered, :web)
      :ok = GenServer.stop(recovered)
    end
  end

  test "does not replace a missing project identity in durable state" do
    for state <- [:sealed, :pointers, :staging] do
      root = state_root()
      {:ok, store} = start_store(root)

      case state do
        :sealed ->
          sealed_web_generations(store, ["missing-id-sealed"])

        :pointers ->
          [first, second] = sealed_web_generations(store, ["missing-id-old", "missing-id-new"])
          assert :ok = ArtifactStore.activate(store, first, 1)
          assert :ok = ArtifactStore.activate(store, second, 2)

        :staging ->
          assert {:ok, _staging} = ArtifactStore.allocate(store, :web)
      end

      :ok = GenServer.stop(store)
      File.rm!(Path.join(root, "project-id"))
      state_before = private_tree_state(root)

      {:ok, recovered} = start_store(root)
      refute File.exists?(Path.join(root, "project-id"))

      assert recovered_state_without_quarantine(root) == state_before
      assert File.regular?(Path.join(root, "quarantine-v1.json"))
      assert {:error, %{code: :cleanup_unconfirmed}} = ArtifactStore.allocate(recovered, :web)
      :ok = GenServer.stop(recovered)
    end
  end

  test "does not initialize child state when a quarantine control already exists" do
    for kind <- [:dangling_symlink, :directory, :regular] do
      root = state_root()
      File.mkdir!(root)
      File.chmod!(root, 0o700)
      quarantine = Path.join(root, "quarantine-v1.json")
      quarantine_control!(quarantine, kind)
      state_before = private_tree_state(root)

      {:ok, store} = start_store(root)
      refute File.exists?(Path.join(root, "project-id"))
      assert private_tree_state(root) == state_before
      assert {:error, %{code: :cleanup_unconfirmed}} = ArtifactStore.allocate(store, :web)
      :ok = GenServer.stop(store)
    end
  end

  test "does not repair a partial durable layout while a quarantine control exists" do
    for kind <- [:dangling_symlink, :directory, :regular] do
      root = state_root()
      {:ok, store} = start_store(root)
      [generation] = sealed_web_generations(store, ["quarantine-control"])
      assert :ok = ArtifactStore.activate(store, generation, 1)
      :ok = GenServer.stop(store)

      for relative <- ["staging", "generations/desktop", "references/desktop", "seals/desktop"] do
        :ok = File.rmdir(Path.join(root, relative))
      end

      quarantine = Path.join(root, "quarantine-v1.json")
      quarantine_control!(quarantine, kind)
      state_before = private_tree_state(root)

      {:ok, recovered} = start_store(root)
      assert private_tree_state(root) == state_before
      assert {:error, %{code: :cleanup_unconfirmed}} = ArtifactStore.allocate(recovered, :web)
      :ok = GenServer.stop(recovered)
    end
  end

  test "recovers publication record writes at every state write boundary" do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    for kind <- [:seal_journal, :seal_metadata, :generation_reference],
        boundary <- state_write_boundaries() do
      root = state_root()
      {:ok, store} = start_store(root)
      {staging, descriptor} = stage_web(store, "#{kind}-#{boundary}")
      expected = generation(staging, descriptor)

      capture_log(fn ->
        assert catch_exit(
                 ArtifactStore.seal(staging, descriptor,
                   checkpoint: state_write_crash_callback(kind, boundary)
                 )
               )

        assert_receive {:EXIT, ^store, :injected_state_write_crash}
      end)

      {:ok, recovered} = start_store(root)
      assert state_temporaries(root) == []

      if kind == :seal_journal do
        refute File.exists?(artifact_path(root, :web, descriptor.artifact_id))
        assert {:error, %{code: :artifact_missing}} = ArtifactStore.acquire(recovered, expected)
      else
        assert {:ok, lease} = ArtifactStore.acquire(recovered, expected)
        assert :ok = ArtifactStore.release(lease)
      end

      assert {:ok, _next} = ArtifactStore.allocate(recovered, :web)
      :ok = GenServer.stop(recovered)
    end
  end

  test "recovers metadata and reference writes interrupted during publication recovery" do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    for kind <- [:seal_metadata, :generation_reference], boundary <- state_write_boundaries() do
      root = state_root()
      {:ok, store} = start_store(root)
      {staging, descriptor} = stage_web(store, "recovery-#{kind}-#{boundary}")
      expected = generation(staging, descriptor)

      capture_log(fn ->
        assert catch_exit(
                 ArtifactStore.seal(staging, descriptor,
                   checkpoint: fn
                     :renamed -> exit(:injected_publication_crash)
                     _other -> :ok
                   end
                 )
               )

        assert_receive {:EXIT, ^store, :injected_publication_crash}
      end)

      {path, record} = recovery_record(root, kind, staging, descriptor)

      if kind == :generation_reference do
        {metadata_path, metadata} = recovery_record(root, :seal_metadata, staging, descriptor)
        assert :ok = Filesystem.atomic_write(metadata_path, metadata, :seal_metadata)
      end

      crash_state_write(path, record, kind, boundary)

      {:ok, recovered} = start_store(root)
      assert state_temporaries(root) == []
      assert {:ok, lease} = ArtifactStore.acquire(recovered, expected)
      assert :ok = ArtifactStore.release(lease)
      assert {:ok, _next} = ArtifactStore.allocate(recovered, :web)
      :ok = GenServer.stop(recovered)
    end
  end

  test "recovers rollback pointer writes at every state write boundary" do
    for boundary <- state_write_boundaries() do
      root = state_root()
      {:ok, store} = start_store(root)
      [first, second] = sealed_web_generations(store, ["old-#{boundary}", "new-#{boundary}"])
      assert :ok = ArtifactStore.activate(store, first, 1)
      :ok = GenServer.stop(store)

      old_current = read_json(Path.join(root, "current/web.json"))
      new_current = pointer_record(second, 2)

      journal = %{
        "v" => 1,
        "target" => "web",
        "old_current" => old_current,
        "old_fallback" => nil,
        "new_current" => new_current
      }

      journal_path = Path.join(root, "activations/web.json")
      File.write!(journal_path, Rekindle.CanonicalValue.encode!(journal))
      File.chmod!(journal_path, 0o600)

      crash_state_write(
        Path.join(root, "current/web.json"),
        new_current,
        :rollback_pointer,
        boundary
      )

      {:ok, recovered} = start_store(root)
      assert state_temporaries(root) == []
      assert File.ls!(Path.join(root, "activations")) == []

      if boundary in [:renamed, :directory_synced] do
        assert {:ok, ^second} = ArtifactStore.current(recovered, :web)
        assert {:ok, ^first} = ArtifactStore.fallback(recovered, :web)
      else
        assert {:ok, ^first} = ArtifactStore.current(recovered, :web)
        assert :none = ArtifactStore.fallback(recovered, :web)
      end

      assert :ok = ArtifactStore.activate(recovered, second, 2)
      :ok = GenServer.stop(recovered)
    end
  end

  test "recovers deletion journal writes at every state write boundary" do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    for boundary <- state_write_boundaries() do
      root = state_root()
      {:ok, store} = start_store(root, retained_generations: 1)
      [first, second] = sealed_web_generations(store, ["delete-#{boundary}", "keep-#{boundary}"])

      capture_log(fn ->
        assert catch_exit(
                 ArtifactStore.collect(store, [],
                   checkpoint: state_write_crash_callback(:deletion_journal, boundary)
                 )
               )

        assert_receive {:EXIT, ^store, :injected_state_write_crash}
      end)

      {:ok, recovered} = start_store(root, retained_generations: 1)
      assert state_temporaries(root) == []
      assert File.dir?(artifact_path(root, :web, second.artifact_id))

      if boundary in [:renamed, :directory_synced] do
        refute File.exists?(artifact_path(root, :web, first.artifact_id))
      else
        assert File.dir?(artifact_path(root, :web, first.artifact_id))
      end

      assert {:ok, _result} = ArtifactStore.collect(recovered)
      :ok = GenServer.stop(recovered)
    end
  end

  test "restores interrupted quarantine writes at every state write boundary" do
    for boundary <- state_write_boundaries() do
      root = state_root()
      {:ok, store} = start_store(root)
      :ok = GenServer.stop(store)

      record = %{"v" => 1, "state" => "cleanup_required", "reason" => "test"}

      crash_state_write(
        Path.join(root, "quarantine-v1.json"),
        record,
        :quarantine,
        boundary
      )

      {:ok, recovered} = start_store(root)
      assert File.regular?(Path.join(root, "quarantine-v1.json"))
      assert state_temporaries(root) == []

      assert {:error, %{code: :cleanup_unconfirmed}} = ArtifactStore.allocate(recovered, :web)
      :ok = GenServer.stop(recovered)
    end
  end

  test "quarantines ambiguous state temporaries without changing them" do
    for mutation <- [
          :legacy,
          :foreign_typed,
          :modified,
          :project_conflict,
          :conflicting,
          :duplicate
        ] do
      root = state_root()
      {:ok, store} = start_store(root)
      :ok = GenServer.stop(store)
      project_id = File.read!(Path.join(root, "project-id"))

      temporaries = ambiguous_state_temporaries(root, mutation, project_id)
      before = Map.new(temporaries, &{&1, File.read!(&1)})

      {:ok, recovered} = start_store(root)
      assert File.regular?(Path.join(root, "quarantine-v1.json"))
      assert Map.new(temporaries, &{&1, File.read!(&1)}) == before
      assert File.read!(Path.join(root, "project-id")) == project_id

      assert {:error, %{code: :cleanup_unconfirmed}} = ArtifactStore.allocate(recovered, :web)
      :ok = GenServer.stop(recovered)
    end
  end

  test "preserves a deletion temporary when its reference is malformed" do
    root = state_root()
    {:ok, store} = start_store(root)
    {staging, descriptor} = stage_web(store, "malformed-deletion-context")
    {:ok, generation} = ArtifactStore.seal(staging, descriptor)
    :ok = GenServer.stop(store)

    reference = Path.join([root, "references", "web", generation.generation_id <> ".json"])
    malformed_reference = Rekindle.CanonicalValue.encode!(%{"v" => 1})
    File.chmod!(reference, 0o600)
    File.write!(reference, malformed_reference)

    journal = %{
      "v" => 1,
      "target" => "web",
      "generation_id" => generation.generation_id,
      "artifact_id" => generation.artifact_id
    }

    bytes = Rekindle.CanonicalValue.encode!(journal)

    name =
      Filesystem.state_temporary_name(
        :deletion_journal,
        generation.generation_id <> ".json",
        Filesystem.sha256_bytes(bytes),
        "00000000000000000000000000000000"
      )

    temporary = Path.join(root, "deletions/#{name}")
    File.write!(temporary, "")
    File.chmod!(temporary, 0o600)

    {:ok, recovered} = start_store(root)
    assert File.read!(reference) == malformed_reference
    assert File.read!(temporary) == ""
    assert File.regular?(Path.join(root, "quarantine-v1.json"))
    assert {:error, %{code: :cleanup_unconfirmed}} = ArtifactStore.allocate(recovered, :web)
    :ok = GenServer.stop(recovered)
  end

  test "preserves a rollback temporary when its prior pointer is malformed" do
    root = state_root()
    {:ok, store} = start_store(root)
    [first, second] = sealed_web_generations(store, ["valid-current", "candidate-current"])
    assert :ok = ArtifactStore.activate(store, first, 1)
    :ok = GenServer.stop(store)

    current_path = Path.join(root, "current/web.json")
    old_current = read_json(current_path)
    new_current = pointer_record(second, 2)

    journal = %{
      "v" => 1,
      "target" => "web",
      "old_current" => old_current,
      "old_fallback" => nil,
      "new_current" => new_current
    }

    journal_path = Path.join(root, "activations/web.json")
    File.write!(journal_path, Rekindle.CanonicalValue.encode!(journal))
    File.chmod!(journal_path, 0o600)

    malformed_pointer = Rekindle.CanonicalValue.encode!(%{"v" => 1})
    File.write!(current_path, malformed_pointer)
    File.chmod!(current_path, 0o600)

    bytes = Rekindle.CanonicalValue.encode!(new_current)

    name =
      Filesystem.state_temporary_name(
        :rollback_pointer,
        "web.json",
        Filesystem.sha256_bytes(bytes),
        "00000000000000000000000000000000"
      )

    temporary = Path.join(root, "current/#{name}")
    File.write!(temporary, bytes)
    File.chmod!(temporary, 0o600)

    {:ok, recovered} = start_store(root)
    assert File.read!(current_path) == malformed_pointer
    assert File.read!(temporary) == bytes
    assert File.regular?(Path.join(root, "quarantine-v1.json"))
    assert {:error, %{code: :cleanup_unconfirmed}} = ArtifactStore.allocate(recovered, :web)
    :ok = GenServer.stop(recovered)
  end

  test "preserves generic state when activation storage contains a foreign temporary" do
    root = state_root()
    {:ok, store} = start_store(root)
    [first, second] = sealed_web_generations(store, ["mixed-old", "mixed-new"])
    assert :ok = ArtifactStore.activate(store, first, 1)
    :ok = GenServer.stop(store)

    current_path = Path.join(root, "current/web.json")
    old_current_bytes = File.read!(current_path)
    old_current = Jason.decode!(old_current_bytes)
    new_current = pointer_record(second, 2)

    journal = %{
      "v" => 1,
      "target" => "web",
      "old_current" => old_current,
      "old_fallback" => nil,
      "new_current" => new_current
    }

    journal_path = Path.join(root, "activations/web.json")
    File.write!(journal_path, Rekindle.CanonicalValue.encode!(journal))
    File.chmod!(journal_path, 0o600)

    generic_bytes = Rekindle.CanonicalValue.encode!(new_current)

    generic_name =
      Filesystem.state_temporary_name(
        :rollback_pointer,
        "web.json",
        Filesystem.sha256_bytes(generic_bytes),
        "00000000000000000000000000000000"
      )

    generic = Path.join(root, "current/#{generic_name}")
    File.write!(generic, generic_bytes)
    File.chmod!(generic, 0o600)

    activation = Path.join(root, "activations/.rekindle-state-v1-foreign.tmp")

    File.write!(activation, "malformed")
    File.chmod!(activation, 0o600)

    {:ok, recovered} = start_store(root)
    assert File.read!(current_path) == old_current_bytes
    assert File.read!(generic) == generic_bytes
    assert File.read!(activation) == "malformed"
    assert File.regular?(Path.join(root, "quarantine-v1.json"))
    assert {:error, %{code: :cleanup_unconfirmed}} = ArtifactStore.allocate(recovered, :web)
    :ok = GenServer.stop(recovered)
  end

  test "does not remove a colliding state temporary it did not create" do
    root = state_root()
    {:ok, store} = start_store(root)
    :ok = GenServer.stop(store)

    path = Path.join(root, "project-id")
    project_id = File.read!(path)
    transaction_id = "00000000000000000000000000000000"

    name =
      Filesystem.state_temporary_name(
        :project_id,
        "project-id",
        Filesystem.sha256_bytes(project_id),
        transaction_id
      )

    temporary = Path.join(root, name)
    File.write!(temporary, "foreign")
    File.chmod!(temporary, 0o600)

    assert {:error, %{code: :io_failed}} =
             Filesystem.atomic_write(path, project_id, :project_id,
               transaction_id: transaction_id
             )

    assert File.read!(temporary) == "foreign"
    assert File.read!(path) == project_id
  end

  test "preserves publication temporaries when their required phase is not proven" do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    for context <- [
          :metadata_before_artifact,
          :metadata_with_invalid_artifact,
          :reference_without_metadata,
          :reference_with_invalid_metadata
        ] do
      root = state_root()
      {:ok, store} = start_store(root)
      {staging, descriptor} = stage_web(store, Atom.to_string(context))
      crash_at = if context == :metadata_before_artifact, do: :journaled, else: :renamed

      capture_log(fn ->
        assert catch_exit(
                 ArtifactStore.seal(staging, descriptor,
                   checkpoint: fn
                     ^crash_at -> exit(:injected_publication_crash)
                     _other -> :ok
                   end
                 )
               )

        assert_receive {:EXIT, ^store, :injected_publication_crash}
      end)

      kind =
        if context in [:metadata_before_artifact, :metadata_with_invalid_artifact],
          do: :seal_metadata,
          else: :generation_reference

      if context == :metadata_with_invalid_artifact do
        member = Path.join(artifact_path(root, :web, descriptor.artifact_id), "members/entry.js")
        File.chmod!(member, 0o600)
        File.write!(member, "changed")
        File.chmod!(member, 0o400)
      end

      if context == :reference_with_invalid_metadata do
        {metadata_path, _record} = recovery_record(root, :seal_metadata, staging, descriptor)
        File.write!(metadata_path, Rekindle.CanonicalValue.encode!(%{"v" => 1}))
        File.chmod!(metadata_path, 0o600)
      end

      {path, record} = recovery_record(root, kind, staging, descriptor)
      temporary = write_state_temporary(path, record, kind)
      before = File.read!(temporary)

      {:ok, recovered} = start_store(root)
      assert File.read!(temporary) == before
      assert File.exists?(Path.dirname(staging.path))
      assert File.regular?(Path.join(root, "quarantine-v1.json"))
      assert {:error, %{code: :cleanup_unconfirmed}} = ArtifactStore.allocate(recovered, :web)
      :ok = GenServer.stop(recovered)
    end
  end

  defp start_store(root, options \\ []) do
    ArtifactStore.start_link(
      Keyword.merge(
        [root: root, retained_generations: 3, max_generation_bytes: 2_147_483_648],
        options
      )
    )
  end

  defp state_write_boundaries,
    do: [:created, :written, :file_synced, :renamed, :directory_synced]

  defp state_write_crash_callback(kind, boundary) do
    fn
      {:artifact_state_write, ^kind, ^boundary} -> exit(:injected_state_write_crash)
      _other -> :ok
    end
  end

  defp crash_state_write(path, value, kind, boundary) do
    {_pid, monitor} =
      spawn_monitor(fn ->
        Filesystem.atomic_write(path, value, kind,
          checkpoint: state_write_crash_callback(kind, boundary)
        )
      end)

    assert_receive {:DOWN, ^monitor, :process, _pid, :injected_state_write_crash}, 5_000
  end

  defp state_temporaries(root) do
    Path.wildcard(Path.join(root, "**/*.tmp"), match_dot: true)
  end

  defp ambiguous_state_temporaries(root, :legacy, _project_id) do
    attempt_id = Filesystem.random_id()
    attempt = Path.join([root, "staging", attempt_id])
    File.mkdir!(attempt)
    File.chmod!(attempt, 0o700)
    File.mkdir!(Path.join(attempt, "body"))
    File.chmod!(Path.join(attempt, "body"), 0o700)
    path = Path.join(attempt, ".attempt-v1.json.00000000000000000000000000000000.tmp")

    marker = %{
      "v" => 1,
      "attempt_id" => attempt_id,
      "generation_id" => Filesystem.random_id(),
      "session_id" => Filesystem.random_id(),
      "target" => "web",
      "owner" => inspect(self())
    }

    File.write!(path, Rekindle.CanonicalValue.encode!(marker))
    File.chmod!(path, 0o600)
    [path]
  end

  defp ambiguous_state_temporaries(root, :foreign_typed, _project_id) do
    name =
      Filesystem.state_temporary_name(
        :attempt_marker,
        "attempt-v1.json",
        Filesystem.sha256_bytes(""),
        "00000000000000000000000000000000"
      )

    path = Path.join(root, name)
    File.write!(path, "")
    File.chmod!(path, 0o600)
    [path]
  end

  defp ambiguous_state_temporaries(root, :modified, project_id) do
    name =
      Filesystem.state_temporary_name(
        :project_id,
        "project-id",
        Filesystem.sha256_bytes(project_id),
        "00000000000000000000000000000000"
      )

    path = Path.join(root, name)
    File.write!(path, "changed")
    File.chmod!(path, 0o600)
    [path]
  end

  defp ambiguous_state_temporaries(root, :project_conflict, project_id) do
    conflicting =
      if project_id == String.duplicate("a", 32),
        do: String.duplicate("b", 32),
        else: String.duplicate("a", 32)

    digest = Filesystem.sha256_bytes(conflicting)

    name =
      Filesystem.state_temporary_name(
        :project_id,
        "project-id",
        digest,
        "00000000000000000000000000000000"
      )

    path = Path.join(root, name)
    File.write!(path, conflicting)
    File.chmod!(path, 0o600)
    [path]
  end

  defp ambiguous_state_temporaries(root, :duplicate, project_id) do
    digest = Filesystem.sha256_bytes(project_id)

    for transaction <- ["00000000000000000000000000000000", "11111111111111111111111111111111"] do
      name = Filesystem.state_temporary_name(:project_id, "project-id", digest, transaction)
      path = Path.join(root, name)
      File.write!(path, project_id)
      File.chmod!(path, 0o600)
      path
    end
  end

  defp ambiguous_state_temporaries(root, :conflicting, _project_id) do
    attempt_id = Filesystem.random_id()
    attempt = Path.join([root, "staging", attempt_id])
    body = Path.join(attempt, "body")
    File.mkdir!(attempt)
    File.chmod!(attempt, 0o700)
    File.mkdir!(body)
    File.chmod!(body, 0o700)

    marker = %{
      "v" => 1,
      "attempt_id" => attempt_id,
      "generation_id" => Filesystem.random_id(),
      "session_id" => Filesystem.random_id(),
      "target" => "web",
      "owner" => inspect(self())
    }

    bytes = Rekindle.CanonicalValue.encode!(marker)
    final = Path.join(attempt, "attempt-v1.json")
    File.write!(final, bytes)
    File.chmod!(final, 0o600)

    name =
      Filesystem.state_temporary_name(
        :attempt_marker,
        "attempt-v1.json",
        Filesystem.sha256_bytes(bytes),
        "00000000000000000000000000000000"
      )

    path = Path.join(attempt, name)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
    [path]
  end

  defp pointer_record(generation, source_revision) do
    %{
      "v" => 1,
      "target" => Atom.to_string(generation.target),
      "generation_id" => generation.generation_id,
      "artifact_id" => generation.artifact_id,
      "manifest_digest" => generation.manifest_digest,
      "source_revision" => source_revision
    }
  end

  defp recovery_record(root, :seal_metadata, _staging, descriptor) do
    path = Path.join([root, "seals", "web", descriptor.artifact_id <> ".json"])

    record = %{
      "v" => 1,
      "target" => "web",
      "descriptor" => descriptor_map(descriptor) |> Map.delete("source_revision")
    }

    {path, record}
  end

  defp recovery_record(root, :generation_reference, staging, descriptor) do
    path = Path.join([root, "references", "web", staging.generation_id <> ".json"])

    record =
      generation(staging, descriptor)
      |> pointer_record(descriptor.source_revision)
      |> Map.put("profile", descriptor.profile)
      |> Map.put("published_at_unix_ms", System.system_time(:millisecond))

    {path, record}
  end

  defp descriptor_map(descriptor) do
    %{
      "artifact_id" => descriptor.artifact_id,
      "manifest_path" => descriptor.manifest_path,
      "manifest_digest" => descriptor.manifest_digest,
      "profile" => descriptor.profile,
      "source_revision" => descriptor.source_revision,
      "members" =>
        Enum.map(descriptor.members, fn member ->
          %{
            "path" => member.path,
            "sha256" => member.sha256,
            "size" => member.size,
            "mode" => Atom.to_string(member.mode)
          }
        end)
    }
  end

  defp write_state_temporary(path, record, kind) do
    bytes = Rekindle.CanonicalValue.encode!(record)

    name =
      Filesystem.state_temporary_name(
        kind,
        Path.basename(path),
        Filesystem.sha256_bytes(bytes),
        "00000000000000000000000000000000"
      )

    temporary = Path.join(Path.dirname(path), name)
    File.write!(temporary, bytes)
    File.chmod!(temporary, 0o600)
    temporary
  end

  defp project_identity_state(root, generations) do
    files =
      Enum.flat_map(generations, fn generation ->
        reference =
          Path.join([root, "references", "web", generation.generation_id <> ".json"])

        artifact = artifact_path(root, :web, generation.artifact_id)

        [reference] ++
          (Path.wildcard(Path.join(artifact, "**/*"))
           |> Enum.filter(&File.regular?/1))
      end) ++
        for(
          kind <- ~w[current fallback],
          path = Path.join([root, kind, "web.json"]),
          File.regular?(path),
          do: path
        )

    files
    |> Enum.uniq()
    |> Enum.sort()
    |> Map.new(&{Path.relative_to(&1, root), File.read!(&1)})
  end

  defp quarantine_control!(path, :dangling_symlink) do
    :ok = File.ln_s("missing-quarantine", path)
  end

  defp quarantine_control!(path, :directory) do
    File.mkdir!(path)
    File.chmod!(path, 0o700)
  end

  defp quarantine_control!(path, :regular) do
    File.write!(path, ~s({"state":"cleanup_required","v":1}))
    File.chmod!(path, 0o600)
  end

  defp private_tree_state(root), do: Map.new(private_tree_entries(root, root))

  defp recovered_state_without_quarantine(root) do
    root
    |> private_tree_state()
    |> Map.delete("quarantine-v1.json")
  end

  defp private_tree_entries(root, path) do
    {:ok, stat} = File.lstat(path)
    relative = Path.relative_to(path, root)

    case stat.type do
      :directory ->
        entry = {relative, {:directory, stat.mode &&& 0o777}}

        children =
          path
          |> File.ls!()
          |> Enum.sort()
          |> Enum.flat_map(&private_tree_entries(root, Path.join(path, &1)))

        [entry | children]

      :regular ->
        [{relative, {:regular, stat.mode &&& 0o777, File.read!(path)}}]

      :symlink ->
        [{relative, {:symlink, File.read_link!(path)}}]

      type ->
        [{relative, {type, stat.mode &&& 0o777}}]
    end
  end

  defp state_root do
    directory = Path.join(System.tmp_dir!(), "rekindle-store-#{Filesystem.random_id()}")

    File.mkdir_p!(directory)
    root = Path.join(directory, ".rekindle")
    on_exit(fn -> File.rm_rf(directory) end)
    root
  end

  defp stage_web(store, content, source_revision \\ 1) do
    {:ok, staging} = ArtifactStore.allocate(store, :web)
    member_path = Path.join(staging.path, "members/entry.js")
    File.mkdir_p!(Path.dirname(member_path))
    File.write!(member_path, content)
    {:ok, member_digest} = Filesystem.sha256(member_path)
    build_key = digest("web-build")

    identity_member = %{
      "path" => "entry.js",
      "role" => "javascript",
      "sha256" => member_digest,
      "size" => byte_size(content)
    }

    artifact_id = artifact_id(:web, build_key, [identity_member])

    manifest_base = %{
      "contract_version" => 2,
      "target" => "web",
      "artifact_id" => artifact_id,
      "build" => %{"build_key" => build_key},
      "members" => [identity_member]
    }

    manifest_digest = manifest_digest(:web, manifest_base)
    manifest = Map.put(manifest_base, "manifest_digest", manifest_digest)

    File.write!(
      Path.join(staging.path, "rekindle-web-manifest-v2.json"),
      Rekindle.CanonicalValue.encode!(manifest)
    )

    descriptor = %Descriptor{
      artifact_id: artifact_id,
      manifest_path: "rekindle-web-manifest-v2.json",
      manifest_digest: manifest_digest,
      profile: "dev",
      source_revision: source_revision,
      members: [
        %Member{
          path: "members/entry.js",
          sha256: member_digest,
          size: byte_size(content),
          mode: :regular
        }
      ]
    }

    {staging, descriptor}
  end

  defp sealed_web_generations(store, contents) do
    contents
    |> Enum.with_index(1)
    |> Enum.map(fn {content, revision} ->
      {staging, descriptor} = stage_web(store, content, revision)
      {:ok, generation} = ArtifactStore.seal(staging, descriptor)
      generation
    end)
  end

  defp injected_activation_failure do
    Rekindle.Failure.new!(
      target: :web,
      stage: :execution,
      code: :io_failed,
      message: "Injected activation failure"
    )
  end

  defp stage_sparse_desktop(store, marker, size) do
    {:ok, staging} = ArtifactStore.allocate(store, :desktop)
    executable = Path.join(staging.path, "application")
    {:ok, io} = File.open(executable, [:write, :binary])
    {:ok, _position} = :file.position(io, size - 1)
    :ok = IO.binwrite(io, <<marker>>)
    :ok = File.close(io)
    :ok = File.chmod(executable, 0o700)
    {:ok, executable_digest} = Filesystem.sha256(executable)
    build_key = digest("desktop-build")

    identity_executable = %{
      "path" => "application",
      "sha256" => executable_digest,
      "size" => size,
      "mode" => "executable_owner"
    }

    artifact_id = artifact_id(:desktop, build_key, identity_executable)

    manifest_base = %{
      "contract_version" => 2,
      "target" => "desktop",
      "artifact_id" => artifact_id,
      "build" => %{"build_key" => build_key},
      "executable" => identity_executable
    }

    manifest_digest = manifest_digest(:desktop, manifest_base)
    manifest = Map.put(manifest_base, "manifest_digest", manifest_digest)

    File.write!(
      Path.join(staging.path, "rekindle-native-manifest-v2.json"),
      Rekindle.CanonicalValue.encode!(manifest)
    )

    descriptor = %Descriptor{
      artifact_id: artifact_id,
      manifest_path: "rekindle-native-manifest-v2.json",
      manifest_digest: manifest_digest,
      profile: "release",
      source_revision: marker,
      members: [
        %Member{
          path: "application",
          sha256: executable_digest,
          size: size,
          mode: :executable_owner
        }
      ]
    }

    {staging, descriptor}
  end

  defp generation(staging, descriptor) do
    %GenerationRef{
      target: staging.target,
      generation_id: staging.generation_id,
      artifact_id: descriptor.artifact_id,
      profile: descriptor.profile,
      manifest_digest: descriptor.manifest_digest
    }
  end

  defp artifact_path(root, target, artifact_id),
    do: Path.join([root, "generations", Atom.to_string(target), artifact_id])

  defp corrupt_pointer(root, kind, :malformed) do
    path = Path.join([root, Atom.to_string(kind), "web.json"])
    if File.exists?(path), do: File.chmod!(path, 0o600)
    File.write!(path, "{")
  end

  defp corrupt_pointer(root, kind, :unreadable) do
    path = Path.join([root, Atom.to_string(kind), "web.json"])
    unless File.exists?(path), do: File.write!(path, "{}")
    File.chmod!(path, 0o000)
  end

  defp persistent_record_fixture(root, kind) when kind in [:pointer, :reference, :seal] do
    {:ok, store} = start_store(root)
    [generation] = sealed_web_generations(store, ["private-#{kind}"])
    assert :ok = ArtifactStore.activate(store, generation, 1)
    :ok = GenServer.stop(store)

    case kind do
      :pointer -> Path.join(root, "current/web.json")
      :reference -> Path.join(root, "references/web/#{generation.generation_id}.json")
      :seal -> Path.join(root, "seals/web/#{generation.artifact_id}.json")
    end
  end

  defp persistent_record_fixture(root, :attempt) do
    {:ok, store} = start_store(root)
    {:ok, staging} = ArtifactStore.allocate(store, :web)
    :ok = GenServer.stop(store)
    Path.join([root, "staging", staging.attempt_id, "attempt-v1.json"])
  end

  defp persistent_record_fixture(root, :activation) do
    {:ok, store} = start_store(root)
    [first, second] = sealed_web_generations(store, ["activation-old", "activation-new"])
    assert :ok = ArtifactStore.activate(store, first, 1)
    :ok = GenServer.stop(store)

    journal = %{
      "v" => 1,
      "target" => "web",
      "old_current" => read_json(Path.join(root, "current/web.json")),
      "old_fallback" => nil,
      "new_current" => pointer_record(second, 2)
    }

    path = Path.join(root, "activations/web.json")
    File.write!(path, Rekindle.CanonicalValue.encode!(journal))
    File.chmod!(path, 0o600)
    path
  end

  defp persistent_record_fixture(root, :deletion) do
    {:ok, store} = start_store(root)
    [generation] = sealed_web_generations(store, ["pending-deletion"])
    :ok = GenServer.stop(store)

    journal = %{
      "v" => 1,
      "target" => "web",
      "generation_id" => generation.generation_id,
      "artifact_id" => generation.artifact_id
    }

    path = Path.join(root, "deletions/#{generation.generation_id}.json")
    File.write!(path, Rekindle.CanonicalValue.encode!(journal))
    File.chmod!(path, 0o600)
    path
  end

  defp substitute_private_record(root, path, mutation) do
    external =
      Path.join(
        Path.dirname(root),
        "external-#{Path.basename(path)}-#{Filesystem.random_id()}"
      )

    case mutation do
      :symlink ->
        File.rename!(path, external)
        :ok = File.ln_s(external, path)
        external

      :hard_link ->
        File.rename!(path, external)
        :ok = File.ln(external, path)
        external

      :unsafe_mode ->
        File.chmod!(path, 0o644)
        nil

      :directory ->
        File.rename!(path, external)
        File.mkdir!(path)
        File.chmod!(path, 0o700)
        external

      :fifo ->
        File.rename!(path, external)
        {_, 0} = System.cmd("mkfifo", [path])
        external
    end
  end

  defp private_node_state(path) do
    {:ok, stat} = File.lstat(path)

    case stat.type do
      :regular -> {:regular, stat.mode &&& 0o777, stat.links, File.read!(path)}
      :symlink -> {:symlink, File.read_link!(path)}
      :directory -> {:directory, stat.mode &&& 0o777, File.ls!(path)}
      type -> {type, stat.mode &&& 0o777, stat.size}
    end
  end

  defp unknown_root_node!(path, :regular) do
    File.write!(path, "unknown")
    File.chmod!(path, 0o600)
  end

  defp unknown_root_node!(path, :directory) do
    File.mkdir!(path)
    File.chmod!(path, 0o700)
  end

  defp unknown_root_node!(path, :symlink), do: File.ln_s!("missing-state", path)

  defp unknown_root_node!(path, :fifo) do
    {_, 0} = System.cmd("mkfifo", [path])
  end

  defp assert_generation_preserved(root, generation) do
    assert File.regular?(
             Path.join([
               root,
               "references",
               Atom.to_string(generation.target),
               generation.generation_id <> ".json"
             ])
           )

    assert File.dir?(artifact_path(root, generation.target, generation.artifact_id))
  end

  defp digest(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp manifest_digest(target, value) do
    domain =
      case target do
        :web -> "rekindle-web-manifest-v2\0"
        :desktop -> "rekindle-native-manifest-v2\0"
      end

    digest(domain <> Rekindle.CanonicalValue.encode!(value))
  end

  defp artifact_id(:web, build_key, members) do
    identity = %{"v" => 2, "build_key" => build_key, "members" => members}
    digest("rekindle-web-artifact-v2\0" <> Rekindle.CanonicalValue.encode!(identity))
  end

  defp artifact_id(:desktop, build_key, executable) do
    identity = %{"v" => 2, "build_key" => build_key, "executable" => executable}
    digest("rekindle-native-artifact-v2\0" <> Rekindle.CanonicalValue.encode!(identity))
  end

  defp wrong_artifact_id(:web, manifest) do
    identity = %{
      "build_key" => manifest["build"]["build_key"],
      "members" => manifest["members"]
    }

    digest("wrong-web-artifact-v1\0" <> Rekindle.CanonicalValue.encode!(identity))
  end

  defp wrong_artifact_id(:desktop, manifest) do
    identity = %{
      "build_key" => manifest["build"]["build_key"],
      "executable" => manifest["executable"]
    }

    digest("wrong-native-artifact-v1\0" <> Rekindle.CanonicalValue.encode!(identity))
  end

  defp mode(path) do
    {:ok, stat} = File.lstat(path)
    stat.mode &&& 0o777
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()

  defp eventually(assertion, attempts \\ 20)
  defp eventually(assertion, 0), do: assertion.()

  defp eventually(assertion, attempts) do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(assertion, attempts - 1)
  end
end
