defmodule Rekindle.Toolchain.CompatibilityManifestTest do
  use ExUnit.Case, async: false

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

  test "explicit source build is authorized by the release descriptor and packaged source" do
    root = temp_root()
    cache = Path.join(root, "cache")
    shadow = Path.join(root, "shadow")
    manifest_path = Path.join(root, "compatibility.json")
    host = Installer.host()
    source = Path.expand("crates/rekindle-toolchain")
    bytes = build_helper_bytes!(source)
    File.mkdir_p!(root)
    rustup = fake_rustup!(root)
    rustup_log = Path.join(root, "rustup.log")
    previous_rustup = System.get_env("REKINDLE_RUSTUP")
    previous_log = System.get_env("REKINDLE_RUSTUP_LOG")

    on_exit(fn ->
      File.rm_rf!(root)
      restore_env("REKINDLE_RUSTUP", previous_rustup)
      restore_env("REKINDLE_RUSTUP_LOG", previous_log)
    end)

    System.put_env("REKINDLE_RUSTUP", rustup)
    System.put_env("REKINDLE_RUSTUP_LOG", rustup_log)
    File.mkdir_p!(Path.join(shadow, "crates/rekindle-toolchain"))

    asset = %{
      "os" => host.os,
      "arch" => host.arch,
      "url" => "https://release.example/rekindle_toolchain",
      "size" => byte_size(bytes),
      "sha256" => sha256(bytes)
    }

    File.write!(manifest_path, Rekindle.CompatibilityFixture.encode(asset))

    result =
      File.cd!(shadow, fn ->
        Release.ensure(true,
          manifest_path: manifest_path,
          cache_root: cache,
          offline: true
        )
      end)

    assert {:ok, path} = result

    assert File.read!(rustup_log) ==
             "run 1.95.0 cargo build --release --locked --offline --manifest-path #{source}/Cargo.toml\n"

    assert File.read!(path) == bytes

    assert String.contains?(
             path,
             Path.join(["0.1.0", "#{host.os}-#{host.arch}", asset["sha256"]])
           )

    mismatch = bytes <> "mismatch"
    mismatch_asset = %{asset | "size" => byte_size(mismatch), "sha256" => sha256(mismatch)}
    mismatch_manifest = Path.join(root, "mismatch.json")
    File.write!(mismatch_manifest, Rekindle.CompatibilityFixture.encode(mismatch_asset))

    assert {:error, %{code: :helper_checksum_mismatch}} =
             Release.ensure(true,
               manifest_path: mismatch_manifest,
               cache_root: Path.join(root, "mismatch"),
               offline: true
             )

    assert rustup_log
           |> File.read!()
           |> String.split("\n", trim: true)
           |> Enum.all?(fn line ->
             String.contains?(line, " --offline ")
           end)

    for override <- [
          [source_root: Path.join(shadow, "crates/rekindle-toolchain")],
          [source_builder: fn _ -> bytes end]
        ] do
      assert {:error, %{code: :helper_missing}} =
               Release.ensure(
                 true,
                 [manifest_path: manifest_path, cache_root: Path.join(root, "override")] ++
                   override
               )
    end
  end

  test "normal acquisition fails closed without the release-generated manifest" do
    assert {:error, %{code: :helper_missing}} =
             Release.ensure(false, manifest_path: "/definitely/missing/compatibility.json")

    assert {:error, %{code: :helper_missing}} =
             Release.ensure(true, manifest_path: "/definitely/missing/compatibility.json")
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp build_helper_bytes!(source) do
    rustup = System.find_executable("rustup") || raise "rustup is required"

    assert {_output, 0} =
             System.cmd(
               rustup,
               [
                 "run",
                 "1.95.0",
                 "cargo",
                 "build",
                 "--release",
                 "--locked",
                 "--manifest-path",
                 Path.join(source, "Cargo.toml")
               ],
               stderr_to_stdout: true
             )

    File.read!(Path.join(source, "target/release/rekindle_toolchain"))
  end

  defp fake_rustup!(root) do
    path = Path.join(root, "rustup")

    File.write!(path, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$REKINDLE_RUSTUP_LOG\"\n")
    File.chmod!(path, 0o700)
    path
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp temp_root do
    Path.join(System.tmp_dir!(), "rekindle-compat-#{System.unique_integer([:positive])}")
  end
end
