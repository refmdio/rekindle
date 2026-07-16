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

    assert {:error, %{code: :helper_checksum_mismatch}} =
             Installer.ensure(asset, options(root, offline: true))

    assert Enum.any?(File.ls!(Path.dirname(path)), &String.contains?(&1, ".quarantine-"))
  end

  test "observed corruption fails online without replacing it and exact mode is required" do
    root = temp_root()
    bytes = "trusted-helper"
    asset = asset(bytes)
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, path} = Installer.ensure(asset, options(root, fetcher: fn _ -> bytes end))
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o700

    File.chmod!(path, 0o711)
    parent = self()

    assert {:error, %{code: :helper_checksum_mismatch}} =
             Installer.ensure(
               asset,
               options(root,
                 fetcher: fn _ ->
                   send(parent, :fetched)
                   bytes
                 end
               )
             )

    refute_received :fetched
    refute File.exists?(path)
    assert Enum.any?(File.ls!(Path.dirname(path)), &String.contains?(&1, ".quarantine-"))
  end

  test "streams into a 0600 temporary and rejects partial or oversized downloads" do
    root = temp_root()
    bytes = "streamed-helper"
    asset = asset(bytes)
    on_exit(fn -> File.rm_rf!(root) end)
    parent = self()

    fetcher = fn _url, io, maximum, temporary ->
      send(parent, {:limit, maximum})
      send(parent, {:mode, Bitwise.band(File.stat!(temporary).mode, 0o777)})
      IO.binwrite(io, binary_part(bytes, 0, 4))
      IO.binwrite(io, binary_part(bytes, 4, byte_size(bytes) - 4))
      :ok
    end

    assert {:ok, path} = Installer.ensure(asset, options(root, fetcher: fetcher))
    assert_receive {:limit, limit}
    assert limit == byte_size(bytes)
    assert_receive {:mode, 0o600}
    assert File.read!(path) == bytes

    File.rm!(path)

    assert {:error, %{code: :helper_checksum_mismatch}} =
             Installer.ensure(
               asset,
               options(root, fetcher: fn _url, io, _max -> IO.binwrite(io, "short") end)
             )

    assert {:error, %{code: :helper_checksum_mismatch}} =
             Installer.ensure(asset, options(root, fetcher: fn _ -> bytes <> "overflow" end))
  end

  test "concurrent installers publish one verified executable without temporary remnants" do
    root = temp_root()
    bytes = "concurrent-helper"
    asset = asset(bytes)
    on_exit(fn -> File.rm_rf!(root) end)

    results =
      1..8
      |> Task.async_stream(
        fn _ -> Installer.ensure(asset, options(root, fetcher: fn _ -> bytes end)) end,
        max_concurrency: 8,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    paths = Enum.map(results, fn {:ok, path} -> path end) |> Enum.uniq()
    assert [path] = paths
    assert File.read!(path) == bytes
    assert Enum.all?(File.ls!(Path.dirname(path)), &(not String.contains?(&1, ".tmp-")))
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
