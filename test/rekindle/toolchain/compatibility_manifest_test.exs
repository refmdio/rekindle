defmodule Rekindle.Toolchain.CompatibilityManifestTest do
  use ExUnit.Case, async: true

  alias Rekindle.Toolchain.{CompatibilityManifest, Helper, Installer, Release}

  test "release asset URL, size and checksum come only from a canonical manifest" do
    root = temp_root()
    manifest_path = Path.join(root, "rekindle-compatibility-v1.json")
    cache = Path.join(root, "cache")
    bytes = "qualified release helper"
    host = Installer.host()
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)

    asset = %{
      "os" => host.os,
      "arch" => host.arch,
      "url" => "https://release.example/rekindle_toolchain",
      "size" => byte_size(bytes),
      "sha256" => sha256(bytes)
    }

    assert Helper.compatibility()["helper_version"] == "0.1.0"
    manifest = Rekindle.CompatibilityFixture.encode(asset)

    File.write!(manifest_path, manifest)

    assert {:ok, path} =
             Release.ensure(false,
               manifest_path: manifest_path,
               cache_root: cache,
               fetcher: fn url ->
                 assert url == asset["url"]
                 bytes
               end
             )

    assert File.read!(path) == bytes
    assert String.contains?(path, asset["sha256"])

    File.write!(manifest_path, manifest <> "\n")

    assert {:error, %{code: :helper_missing}} =
             Release.ensure(false, manifest_path: manifest_path, cache_root: cache)
  end

  test "loads the full release schema and rejects tuple, evidence, template and helper tampering" do
    root = temp_root()
    path = Path.join(root, "compatibility.json")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    host = Installer.host()

    asset = %{
      "os" => host.os,
      "arch" => host.arch,
      "url" => "https://release.example/rekindle_toolchain",
      "size" => 10,
      "sha256" => String.duplicate("a", 64)
    }

    release = Rekindle.CompatibilityFixture.release(asset)
    File.write!(path, CompatibilityManifest.encode_release!(release))
    assert {:ok, manifest} = CompatibilityManifest.load(manifest_path: path)
    assert manifest.root["targets"]["web"]["rust_toolchain"] == "nightly-2026-04-01"
    assert length(manifest.root["tuples"]) == 2

    tampered_values = [
      put_in(release, ["client_template", "manifest_sha256"], String.duplicate("b", 64)),
      put_in(release, ["helper", "assets", Access.at(0), "sha256"], String.duplicate("b", 64)),
      update_in(release["evidence"], &tl/1),
      update_in(release["tuples"], &Enum.reverse/1),
      Map.put(release, "shadow_helper_manifest", %{}),
      put_in(release, ["elixir", "tested"], ["1.19.0", "1.20.2"]),
      put_in(release, ["endpoint_adapters", Access.at(0), "tested"], ["1.12.0", "1.13.0"]),
      update_in(release["tuples"], fn [first | rest] ->
        [%{first | "tuple_id" => String.duplicate("0", 64)} | rest]
      end)
    ]

    for tampered <- tampered_values do
      File.write!(path, CompatibilityManifest.encode_release!(tampered))
      assert {:error, %{code: :helper_missing}} = CompatibilityManifest.load(manifest_path: path)
    end
  end

  test "explicit source build derives its descriptor from built bytes without a URL" do
    root = temp_root()
    bytes = "locally reproduced helper"
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, path} =
             Release.ensure(true,
               cache_root: root,
               offline: true,
               source_builder: fn -> bytes end
             )

    assert File.read!(path) == bytes
    assert String.contains?(path, sha256(bytes))
  end

  test "normal acquisition fails closed without the release-generated manifest" do
    assert {:error, %{code: :helper_missing}} =
             Release.ensure(false, manifest_path: "/definitely/missing/compatibility.json")
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp temp_root do
    Path.join(System.tmp_dir!(), "rekindle-compat-#{System.unique_integer([:positive])}")
  end
end
