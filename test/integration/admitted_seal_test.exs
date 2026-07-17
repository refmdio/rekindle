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

  defp store do
    directory = Path.join(System.tmp_dir!(), "rekindle-admission-#{Filesystem.random_id()}")
    File.mkdir_p!(directory)
    root = Path.join(directory, ".rekindle")
    on_exit(fn -> File.rm_rf(directory) end)
    start_supervised!({ArtifactStore, root: root})
  end

  defp seal(store, target, producer_kind, source_revision) do
    {:ok, staging} = ArtifactStore.allocate(store, target)
    profile = if target == :web, do: "dev", else: "release"
    producer = producer(target, producer_kind)
    artifact_id = digest("#{target}:#{producer_kind}:#{source_revision}")
    {manifest_path, member} = write_member(staging.path, target, source_revision)

    manifest = manifest(target, artifact_id, profile, producer, member)
    manifest_digest = manifest_digest(target, manifest)
    manifest = Map.put(manifest, "manifest_digest", manifest_digest)
    File.write!(Path.join(staging.path, manifest_path), CanonicalValue.encode!(manifest))

    descriptor = %Descriptor{
      artifact_id: artifact_id,
      manifest_path: manifest_path,
      manifest_digest: manifest_digest,
      profile: profile,
      source_revision: source_revision,
      members: [member.descriptor]
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

  defp write_member(root, :web, revision) do
    path = "members/entry.js"
    File.mkdir_p!(Path.dirname(Path.join(root, path)))
    bytes = "export const revision = #{revision};\n"
    File.write!(Path.join(root, path), bytes)
    digest = digest(bytes)

    {"rekindle-web-manifest-v1.json",
     %{
       descriptor: %Member{path: path, sha256: digest, size: byte_size(bytes), mode: :regular},
       manifest: %{
         "path" => "entry.js",
         "role" => "bootstrap",
         "sha256" => digest,
         "size" => byte_size(bytes),
         "mime" => "text/javascript",
         "cache" => "no_cache",
         "source_map" => nil
       }
     }}
  end

  defp write_member(root, :desktop, revision) do
    path = "application"
    bytes = "desktop-#{revision}"
    File.write!(Path.join(root, path), bytes)
    File.chmod!(Path.join(root, path), 0o700)
    digest = digest(bytes)

    {"rekindle-native-manifest-v1.json",
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
     }}
  end

  defp manifest(:web, artifact_id, profile, producer, member) do
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
      "members" => [member.manifest],
      "edges" => []
    }
  end

  defp manifest(:desktop, artifact_id, profile, producer, member) do
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

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
