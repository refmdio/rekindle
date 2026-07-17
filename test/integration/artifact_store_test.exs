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
    assert Enum.sort(File.ls!(artifact)) == ["members", "rekindle-web-manifest-v1.json"]
    assert Enum.sort(File.ls!(Path.join(artifact, "members"))) == ["entry.js"]
    assert mode(artifact) == 0o500
    assert mode(Path.join(artifact, "members")) == 0o500
    assert mode(Path.join(artifact, "members/entry.js")) == 0o400
    assert mode(Path.join(artifact, "rekindle-web-manifest-v1.json")) == 0o400
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

  test "rejects escaping, aliased, extra, changed, linked, and special members" do
    for mutation <- [:traversal, :collision, :extra, :digest, :manifest, :symlink, :hard_link] do
      root = state_root()
      {:ok, store} = start_store(root)
      {staging, descriptor} = stage_web(store, "entry")

      descriptor =
        case mutation do
          :traversal ->
            %{descriptor | members: [%{hd(descriptor.members) | path: "../entry.js"}]}

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
              "../rekindle-web-manifest-v1.json",
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

    assert_receive {:sealed_not_renamed, artifact_id, source_parent_mode, target_parent_mode}
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
    assert :none = ArtifactStore.current(quarantined, :web)

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

  defp start_store(root, options \\ []) do
    ArtifactStore.start_link(
      Keyword.merge(
        [root: root, retained_generations: 3, max_generation_bytes: 2_147_483_648],
        options
      )
    )
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
    artifact_id = digest("web:" <> content)

    manifest_base = %{
      "contract_version" => 1,
      "target" => "web",
      "artifact_id" => artifact_id
    }

    manifest_digest = manifest_digest(:web, manifest_base)
    manifest = Map.put(manifest_base, "manifest_digest", manifest_digest)

    File.write!(
      Path.join(staging.path, "rekindle-web-manifest-v1.json"),
      Rekindle.CanonicalValue.encode!(manifest)
    )

    descriptor = %Descriptor{
      artifact_id: artifact_id,
      manifest_path: "rekindle-web-manifest-v1.json",
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

  defp stage_sparse_desktop(store, marker, size) do
    {:ok, staging} = ArtifactStore.allocate(store, :desktop)
    executable = Path.join(staging.path, "application")
    {:ok, io} = File.open(executable, [:write, :binary])
    {:ok, _position} = :file.position(io, size - 1)
    :ok = IO.binwrite(io, <<marker>>)
    :ok = File.close(io)
    :ok = File.chmod(executable, 0o700)
    {:ok, executable_digest} = Filesystem.sha256(executable)
    artifact_id = digest("desktop:#{marker}")

    manifest_base = %{
      "contract_version" => 1,
      "target" => "desktop",
      "artifact_id" => artifact_id
    }

    manifest_digest = manifest_digest(:desktop, manifest_base)
    manifest = Map.put(manifest_base, "manifest_digest", manifest_digest)

    File.write!(
      Path.join(staging.path, "rekindle-native-manifest-v1.json"),
      Rekindle.CanonicalValue.encode!(manifest)
    )

    descriptor = %Descriptor{
      artifact_id: artifact_id,
      manifest_path: "rekindle-native-manifest-v1.json",
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

  defp digest(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp manifest_digest(target, value) do
    domain =
      case target do
        :web -> "rekindle-web-manifest-v1\0"
        :desktop -> "rekindle-native-manifest-v1\0"
      end

    digest(domain <> Rekindle.CanonicalValue.encode!(value))
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
