defmodule Rekindle.AdmittedSealTest do
  use ExUnit.Case, async: true

  alias Rekindle.ArtifactStore
  alias Rekindle.ArtifactStore.{Descriptor, Filesystem, Member}
  alias Rekindle.SealedArtifact.{Desktop, Web}
  alias Rekindle.{AdmittedSeal, CanonicalValue, GenerationRef}

  test "canonical and extension producers admit both target unions without publication" do
    store = store()

    for {target, producer_kind, revision} <- [
          {:web, :canonical, 1},
          {:web, :extension, 2},
          {:desktop, :canonical, 3},
          {:desktop, :extension, 4}
        ] do
      sealed = seal(store, target, producer_kind, revision)
      assert :none = ArtifactStore.current(store, target)
      assert {:ok, admitted} = AdmittedSeal.admit(store, sealed)
      assert {:ok, value} = AdmittedSeal.fetch(admitted)
      assert value.target == target
      assert value.source_revision == revision
      assert value.seal_result == :sealed
      assert value.producer.kind == expected_producer(target, producer_kind)
      assert :none = ArtifactStore.current(store, target)
    end
  end

  test "admission rejects stale and unsealed generation references" do
    store = store()
    sealed = seal(store, :web, :canonical, 10)

    stale = rebuild(sealed, source_revision: 11)
    assert {:error, %{code: :artifact_missing}} = AdmittedSeal.admit(store, stale)

    unsealed_generation = %GenerationRef{
      sealed.generation
      | generation_id: String.duplicate("f", 32)
    }

    unsealed = rebuild(sealed, generation: unsealed_generation)
    assert {:error, %{code: :artifact_missing}} = AdmittedSeal.admit(store, unsealed)
  end

  test "target, producer, identity, and unknown-field mismatches fail before admission" do
    store = store()
    sealed = seal(store, :web, :canonical, 20)

    assert {:error, %{code: :manifest_invalid}} =
             AdmittedSeal.admit(store, %{
               sealed
               | producer: %{sealed.producer | kind: :extension}
             })

    assert {:error, %{code: :manifest_invalid}} =
             Web.new(
               generation: sealed.generation,
               source_revision: sealed.source_revision,
               manifest: sealed.manifest,
               seal_result: :sealed,
               extra: true
             )

    assert {:error, %{code: :manifest_invalid}} =
             sealed.manifest
             |> Map.put("unknown", true)
             |> rebuild_manifest(sealed)

    assert {:error, %{code: :manifest_invalid}} =
             sealed.manifest
             |> put_in(["producer", "kind"], "canonical_desktop")
             |> rebuild_manifest(sealed)

    assert {:error, %{code: :manifest_invalid}} =
             sealed.manifest
             |> Map.put("target", "desktop")
             |> rebuild_manifest(sealed)

    assert {:error, %{code: :manifest_invalid}} =
             sealed.manifest
             |> Map.put("artifact_id", String.duplicate("0", 64))
             |> rebuild_manifest(sealed)
  end

  test "sealed contracts reject self-consistent asserted identities" do
    store = store()

    for {target, revision} <- [web: 21, desktop: 22] do
      sealed = seal(store, target, :extension, revision)
      asserted = String.duplicate(if(target == :web, do: "a", else: "e"), 64)

      manifest =
        sealed.manifest
        |> Map.put("artifact_id", asserted)
        |> Map.delete("manifest_digest")

      manifest_digest = manifest_digest(target, manifest)
      manifest = Map.put(manifest, "manifest_digest", manifest_digest)

      generation = %{
        sealed.generation
        | artifact_id: asserted,
          manifest_digest: manifest_digest
      }

      module = if target == :web, do: Web, else: Desktop

      assert {:error, %{code: :manifest_invalid}} =
               module.new(
                 generation: generation,
                 source_revision: sealed.source_revision,
                 manifest: manifest,
                 seal_result: :sealed
               )
    end
  end

  test "lease substitution, union changes, and post-admission mutation are detected" do
    store = store()
    first = seal(store, :web, :canonical, 30)
    second = seal(store, :web, :canonical, 31)
    assert {:ok, admitted} = AdmittedSeal.admit(store, first)
    assert {:ok, second_admitted} = AdmittedSeal.admit(store, second)

    assert {:error, %{code: :manifest_invalid}} =
             AdmittedSeal.fetch(%{admitted | artifact_id: String.duplicate("0", 64)})

    assert {:error, %{code: :manifest_invalid}} =
             AdmittedSeal.fetch(%{admitted | sealed: {:desktop, first}})

    changed_seal = %{first | manifest: put_in(first.manifest, ["build", "binary"], "changed")}

    assert {:error, %{code: :manifest_invalid}} =
             AdmittedSeal.fetch(%{admitted | sealed: {:web, changed_seal}})

    assert {:error, %{code: :manifest_invalid}} =
             AdmittedSeal.fetch(%{admitted | lease: second_admitted.lease})

    :ok = ArtifactStore.release(admitted.lease)
    assert {:error, %{code: :manifest_invalid}} = AdmittedSeal.fetch(admitted)
  end

  test "web and desktop consumers use only the common admitted interface" do
    store = store()
    web = seal(store, :web, :extension, 40)
    desktop = seal(store, :desktop, :extension, 41)
    assert {:ok, web} = AdmittedSeal.admit(store, web)
    assert {:ok, desktop} = AdmittedSeal.admit(store, desktop)

    assert {:web, web.artifact_id} == consume_for_web(web)
    assert {:desktop, desktop.artifact_id} == consume_for_desktop(desktop)
  end

  test "web contracts reject missing roles and unresolved manifest references" do
    store = store()

    for {producer_kind, revision} <- [canonical: 50, extension: 51] do
      sealed = seal(store, :web, producer_kind, revision)

      mutations = [
        &remove_web_role(&1, "bootstrap"),
        &remove_web_role(&1, "javascript"),
        &remove_web_role(&1, "wasm"),
        &Map.put(&1, "entry", "missing.js"),
        &Map.put(&1, "hot_styles", ["missing.css"]),
        fn manifest ->
          update_in(manifest, ["members"], fn members ->
            Enum.map(members, fn
              %{"role" => "javascript"} = member ->
                %{member | "source_map" => "missing.map"}

              member ->
                member
            end)
          end)
        end,
        fn manifest ->
          update_in(manifest, ["edges"], fn edges ->
            Enum.map(edges, fn
              %{"kind" => "dynamic_import"} = edge -> %{edge | "to" => "missing.js"}
              edge -> edge
            end)
          end)
        end
      ]

      for mutation <- mutations do
        assert {:error, %{code: :manifest_invalid}} =
                 rebuild_web_contract(sealed, mutation.(sealed.manifest))
      end
    end
  end

  test "admission binds every manifest member field to sealed store metadata" do
    for {producer_kind, producer_offset} <- [canonical: 0, extension: 100],
        {target, target_offset} <- [web: 0, desktop: 10],
        {mismatch, mismatch_offset} <- Enum.with_index([:path, :hash, :size, :mode], 1) do
      store = store()
      revision = 1000 + producer_offset + target_offset + mismatch_offset
      sealed = mismatched_seal(store, target, producer_kind, revision, mismatch)

      assert {:error, %{code: :manifest_invalid}} = AdmittedSeal.admit(store, sealed)
    end
  end

  test "failed store binding releases the provisional lease" do
    store = store(retained_generations: 1)
    sealed = mismatched_seal(store, :web, :canonical, 1200, :hash)

    assert {:error, %{code: :manifest_invalid}} = AdmittedSeal.admit(store, sealed)
    _newer = seal(store, :web, :canonical, 1201)
    assert {:ok, %{removed_generations: 1}} = ArtifactStore.collect(store)
  end

  defp consume_for_web(admitted) do
    {:ok, %{target: :web, sealed: {:web, _sealed}, artifact_id: artifact_id}} =
      AdmittedSeal.fetch(admitted)

    {:web, artifact_id}
  end

  defp consume_for_desktop(admitted) do
    {:ok, %{target: :desktop, sealed: {:desktop, _sealed}, artifact_id: artifact_id}} =
      AdmittedSeal.fetch(admitted)

    {:desktop, artifact_id}
  end

  defp rebuild(%Web{} = sealed, replacements) do
    attributes =
      sealed
      |> Map.from_struct()
      |> Map.take(~w[generation source_revision manifest seal_result]a)
      |> Map.merge(Map.new(replacements))

    {:ok, rebuilt} = Web.new(attributes)
    rebuilt
  end

  defp rebuild_manifest(manifest, %Web{} = sealed) do
    Web.new(
      generation: sealed.generation,
      source_revision: sealed.source_revision,
      manifest: manifest,
      seal_result: :sealed
    )
  end

  defp rebuild_web_contract(%Web{} = sealed, manifest) do
    manifest = Map.delete(manifest, "manifest_digest")
    manifest_digest = manifest_digest(:web, manifest)
    manifest = Map.put(manifest, "manifest_digest", manifest_digest)
    generation = %{sealed.generation | manifest_digest: manifest_digest}

    Web.new(
      generation: generation,
      source_revision: sealed.source_revision,
      manifest: manifest,
      seal_result: :sealed
    )
  end

  defp remove_web_role(manifest, role) do
    removed =
      manifest["members"]
      |> Enum.filter(&(&1["role"] == role))
      |> Enum.map(& &1["path"])
      |> MapSet.new()

    manifest
    |> Map.update!("members", &Enum.reject(&1, fn member -> member["role"] == role end))
    |> Map.update!("edges", fn edges ->
      Enum.reject(
        edges,
        &(MapSet.member?(removed, &1["from"]) or MapSet.member?(removed, &1["to"]))
      )
    end)
  end

  defp store(options \\ []) do
    directory = Path.join(System.tmp_dir!(), "rekindle-admission-#{Filesystem.random_id()}")
    File.mkdir_p!(directory)
    root = Path.join(directory, ".rekindle")
    on_exit(fn -> File.rm_rf(directory) end)

    start_supervised!(
      Supervisor.child_spec(
        {ArtifactStore, Keyword.put(options, :root, root)},
        id: {ArtifactStore, root}
      )
    )
  end

  defp seal(store, target, producer_kind, source_revision) do
    {:ok, staging} = ArtifactStore.allocate(store, target)
    profile = if target == :web, do: "dev", else: "release"
    producer = producer(target, producer_kind)
    {manifest_path, members} = write_members(staging.path, target, source_revision)
    artifact_id = artifact_id(target, build(profile)["build_key"], members)

    manifest = manifest(target, artifact_id, profile, producer, members)
    manifest_digest = manifest_digest(target, manifest)
    manifest = Map.put(manifest, "manifest_digest", manifest_digest)
    File.write!(Path.join(staging.path, manifest_path), CanonicalValue.encode!(manifest))

    descriptor = %Descriptor{
      artifact_id: artifact_id,
      manifest_path: manifest_path,
      manifest_digest: manifest_digest,
      profile: profile,
      source_revision: source_revision,
      members: Enum.map(members, & &1.descriptor)
    }

    assert {:ok, generation} = ArtifactStore.seal(staging, descriptor)
    module = if target == :web, do: Web, else: Desktop

    assert {:ok, sealed} =
             module.new(
               generation: generation,
               source_revision: source_revision,
               manifest: manifest,
               seal_result: :sealed
             )

    sealed
  end

  defp mismatched_seal(store, target, producer_kind, source_revision, mismatch) do
    {:ok, staging} = ArtifactStore.allocate(store, target)
    profile = if target == :web, do: "dev", else: "release"
    producer = producer(target, producer_kind)
    {manifest_path, members} = write_members(staging.path, target, source_revision)
    {members, manifest_members} = mismatch_members(staging.path, target, members, mismatch)
    artifact_id = artifact_id(target, build(profile)["build_key"], manifest_members)

    manifest = manifest(target, artifact_id, profile, producer, manifest_members)
    manifest_digest = manifest_digest(target, manifest)
    manifest = Map.put(manifest, "manifest_digest", manifest_digest)
    File.write!(Path.join(staging.path, manifest_path), CanonicalValue.encode!(manifest))

    descriptor = %Descriptor{
      artifact_id: artifact_id,
      manifest_path: manifest_path,
      manifest_digest: manifest_digest,
      profile: profile,
      source_revision: source_revision,
      members: Enum.map(members, & &1.descriptor)
    }

    assert {:ok, generation} = ArtifactStore.seal(staging, descriptor)
    module = if target == :web, do: Web, else: Desktop

    assert {:ok, sealed} =
             module.new(
               generation: generation,
               source_revision: source_revision,
               manifest: manifest,
               seal_result: :sealed
             )

    sealed
  end

  defp mismatch_members(root, target, members, :path) do
    [selected | rest] = members
    old_path = selected.descriptor.path
    new_path = if target == :web, do: "members/renamed.js", else: "renamed-application"
    File.rename!(Path.join(root, old_path), Path.join(root, new_path))
    selected = %{selected | descriptor: %{selected.descriptor | path: new_path}}
    {[selected | rest], members}
  end

  defp mismatch_members(_root, _target, members, :hash) do
    [selected | rest] = members
    selected = put_in(selected, [:manifest, "sha256"], String.duplicate("0", 64))
    {members, [selected | rest]}
  end

  defp mismatch_members(_root, _target, members, :size) do
    [selected | rest] = members
    selected = update_in(selected, [:manifest, "size"], &(&1 + 1))
    {members, [selected | rest]}
  end

  defp mismatch_members(root, target, members, :mode) do
    [selected | rest] = members
    path = Path.join(root, selected.descriptor.path)
    mode = if target == :web, do: :executable_owner, else: :regular
    File.chmod!(path, if(mode == :executable_owner, do: 0o700, else: 0o600))
    selected = %{selected | descriptor: %{selected.descriptor | mode: mode}}
    {[selected | rest], members}
  end

  defp write_members(root, :web, revision) do
    members = [
      web_member(root, "app.js", "javascript", "fetch('./app.wasm'); #{revision}\n"),
      web_member(root, "app.wasm", "wasm", "wasm-#{revision}"),
      web_member(root, "entry.js", "bootstrap", "import('./app.js');\n")
    ]

    {"rekindle-web-manifest-v1.json", members}
  end

  defp write_members(root, :desktop, revision) do
    path = "application"
    bytes = "desktop-#{revision}"
    File.write!(Path.join(root, path), bytes)
    File.chmod!(Path.join(root, path), 0o700)
    digest = digest(bytes)

    {"rekindle-native-manifest-v1.json",
     [
       %{
         descriptor: %Member{
           path: path,
           sha256: digest,
           size: byte_size(bytes),
           mode: :executable_owner
         },
         manifest: %{
           "path" => path,
           "sha256" => digest,
           "size" => byte_size(bytes),
           "mode" => "executable_owner"
         }
       }
     ]}
  end

  defp web_member(root, path, role, bytes) do
    descriptor_path = "members/" <> path
    File.mkdir_p!(Path.dirname(Path.join(root, descriptor_path)))
    File.write!(Path.join(root, descriptor_path), bytes)
    sha256 = digest(bytes)

    {mime, cache} =
      case role do
        "bootstrap" -> {"text/javascript; charset=utf-8", "no_cache"}
        "javascript" -> {"text/javascript; charset=utf-8", "immutable"}
        "wasm" -> {"application/wasm", "immutable"}
      end

    %{
      descriptor: %Member{
        path: descriptor_path,
        sha256: sha256,
        size: byte_size(bytes),
        mode: :regular
      },
      manifest: %{
        "path" => path,
        "role" => role,
        "sha256" => sha256,
        "size" => byte_size(bytes),
        "mime" => mime,
        "cache" => cache,
        "source_map" => nil
      }
    }
  end

  defp manifest(:web, artifact_id, profile, producer, members) do
    %{
      "contract_version" => 1,
      "rekindle_version" => "0.1.0",
      "application_id" => "editor",
      "target" => "web",
      "artifact_id" => artifact_id,
      "build" => build(profile),
      "producer" => producer,
      "host_requirements" => %{"secure_context" => true, "webgpu" => true},
      "entry" => "entry.js",
      "hot_styles" => [],
      "members" => Enum.map(members, & &1.manifest),
      "edges" => [
        %{"from" => "app.js", "to" => "app.wasm", "kind" => "wasm_url"},
        %{"from" => "entry.js", "to" => "app.js", "kind" => "dynamic_import"}
      ]
    }
  end

  defp manifest(:desktop, artifact_id, profile, producer, [member]) do
    %{
      "contract_version" => 1,
      "rekindle_version" => "0.1.0",
      "application_id" => "editor",
      "target" => "desktop",
      "artifact_id" => artifact_id,
      "build" => build(profile),
      "platform" => %{
        "os" => "linux",
        "arch" => "x86_64",
        "target_triple" => "x86_64-unknown-linux-gnu"
      },
      "producer" => producer,
      "executable" => member.manifest,
      "runtime" => %{"readiness" => "ipc_v1", "handoff" => "ipc_v1"}
    }
  end

  defp build(profile) do
    %{
      "build_key" => String.duplicate("b", 64),
      "profile" => profile,
      "package" => "editor",
      "binary" => "editor",
      "features" => []
    }
  end

  defp producer(target, :canonical) do
    common = %{
      "rustc" => "1.95.0",
      "cargo" => "1.95.0",
      "rust_target" =>
        if(target == :web, do: "wasm32-unknown-unknown", else: "x86_64-unknown-linux-gnu"),
      "gpui_revision" => "18f35ffac2da72ccdfb0e1bf756218fa1995162b",
      "helper_version" => "0.1.0",
      "helper_protocol" => 1,
      "compatibility_tuple_id" => String.duplicate("c", 64)
    }

    if target == :web,
      do: Map.merge(common, %{"kind" => "canonical_web", "wasm_bindgen" => "0.2.100"}),
      else: Map.put(common, "kind", "canonical_desktop")
  end

  defp producer(_target, :extension) do
    %{
      "kind" => "extension",
      "backend_id" => "example.backend",
      "backend_version" => "1.0.0",
      "options_digest" => String.duplicate("d", 64)
    }
  end

  defp expected_producer(:web, :canonical), do: :canonical_web
  defp expected_producer(:desktop, :canonical), do: :canonical_desktop
  defp expected_producer(_target, :extension), do: :extension

  defp manifest_digest(target, manifest) do
    domain =
      if target == :web, do: "rekindle-web-manifest-v1\0", else: "rekindle-native-manifest-v1\0"

    :crypto.hash(:sha256, domain <> CanonicalValue.encode!(manifest))
    |> Base.encode16(case: :lower)
  end

  defp artifact_id(:web, build_key, members) do
    identity = %{
      "v" => 1,
      "build_key" => build_key,
      "members" => Enum.map(members, &Map.take(&1.manifest, ~w[path role sha256 size]))
    }

    digest("rekindle-web-artifact-v1\0" <> CanonicalValue.encode!(identity))
  end

  defp artifact_id(:desktop, build_key, [executable]) do
    identity = %{
      "v" => 1,
      "build_key" => build_key,
      "executable" => Map.take(executable.manifest, ~w[path sha256 size mode])
    }

    digest("rekindle-native-artifact-v1\0" <> CanonicalValue.encode!(identity))
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
