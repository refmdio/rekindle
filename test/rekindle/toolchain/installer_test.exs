defmodule Rekindle.Toolchain.InstallerTest do
  use ExUnit.Case, async: true

  alias Rekindle.Toolchain.Installer

  test "downloads, verifies, reuses offline, and quarantines corruption" do
    root = temp_root()
    bytes = "trusted-helper"
    asset = asset(bytes)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, path} = Installer.ensure(asset, options(root, fetcher: fn _ -> bytes end))
    assert File.read!(path) == bytes
    assert {:ok, ^path} = Installer.ensure(asset, options(root, offline: true))

    File.write!(path, "corrupt")

    assert {:error, %{code: :helper_missing}} =
             Installer.ensure(asset, options(root, offline: true))

    assert Enum.any?(File.ls!(Path.dirname(path)), &String.contains?(&1, ".quarantine-"))
  end

  test "requires exact checksum and explicit source build" do
    root = temp_root()
    bytes = "source-helper"
    asset = asset(bytes)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, %{code: :helper_checksum_mismatch}} =
             Installer.ensure(asset, options(root, fetcher: fn _ -> "wrong" end))

    assert {:ok, path} =
             Installer.ensure(
               asset,
               options(root,
                 source_build: true,
                 source_builder: fn ^asset -> bytes end
               )
             )

    assert Path.type(path) == :absolute
  end

  test "rejects an unsupported host without a PATH fallback" do
    root = temp_root()
    asset = asset("bytes") |> Map.put("os", "not-this-host")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, %{code: :unsupported_host}} = Installer.ensure(asset, options(root))
  end

  defp asset(bytes) do
    host = Installer.host()

    %{
      "os" => host.os,
      "arch" => host.arch,
      "url" => "https://example.invalid/rekindle_toolchain",
      "size" => byte_size(bytes),
      "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    }
  end

  defp options(root, extra \\ []) do
    [cache_root: root, rekindle_version: "0.1.0"] |> Keyword.merge(extra)
  end

  defp temp_root do
    Path.join(System.tmp_dir!(), "rekindle-helper-#{System.unique_integer([:positive])}")
  end
end
