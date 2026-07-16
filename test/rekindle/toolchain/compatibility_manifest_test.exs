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

    manifest =
      CompatibilityManifest.encode_helper_release!(%{
        "rekindle_version" => "0.1.0",
        "helper" => %{
          "protocol" => 1,
          "version" => Helper.compatibility()["helper_version"],
          "assets" => [asset]
        }
      })

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
