defmodule Rekindle.Toolchain.TargetInstallerTest do
  use ExUnit.Case, async: false

  alias Rekindle.Toolchain.TargetInstaller

  setup do
    original_rustup = System.get_env("REKINDLE_RUSTUP")
    original_log = System.get_env("REKINDLE_RUSTUP_LOG")

    on_exit(fn ->
      restore_env("REKINDLE_RUSTUP", original_rustup)
      restore_env("REKINDLE_RUSTUP_LOG", original_log)
    end)

    :ok
  end

  test "installs the pinned toolchain and Web target through a qualified rustup" do
    root = temp_dir!()
    log = Path.join(root, "rustup.log")
    rustup = fake_rustup!(root)
    System.put_env("REKINDLE_RUSTUP", rustup)
    System.put_env("REKINDLE_RUSTUP_LOG", log)

    config = %{
      backend: :canonical,
      toolchain: %{kind: :rustup, name: "1.95.0"},
      rust_target: "wasm32-unknown-unknown"
    }

    assert {:ok, %{status: :verified, rust_target: "wasm32-unknown-unknown"}} =
             TargetInstaller.ensure(:web, config)

    assert File.read!(log) ==
             "toolchain install 1.95.0 --profile minimal\n" <>
               "target add --toolchain 1.95.0 wasm32-unknown-unknown\n"
  end

  test "an explicit invalid rustup override fails closed" do
    System.put_env("REKINDLE_RUSTUP", Path.join(temp_dir!(), "missing-rustup"))

    config = %{
      backend: :canonical,
      toolchain: %{kind: :rustup, name: "1.95.0"},
      rust_target: nil
    }

    assert {:error, %{code: :tool_missing}} = TargetInstaller.ensure(:desktop, config)
  end

  test "rejects symlinked rustup paths and replacement before spawn" do
    root = temp_dir!()
    rustup = fake_rustup!(root)
    linked = Path.join(root, "rustup-link")
    File.ln_s!(rustup, linked)
    System.put_env("REKINDLE_RUSTUP", linked)

    config = %{
      backend: :canonical,
      toolchain: %{kind: :rustup, name: "1.95.0"},
      rust_target: nil
    }

    assert {:error, %{code: :tool_missing}} = TargetInstaller.ensure(:desktop, config)

    System.put_env("REKINDLE_RUSTUP", rustup)
    replacement = Path.join(root, "rustup-replacement")
    File.cp!(rustup, replacement)
    File.chmod!(replacement, 0o700)

    hook = fn ->
      File.rename!(replacement, rustup)
      :ok
    end

    assert {:error, %{code: :tool_missing}} =
             TargetInstaller.ensure(:desktop, config, before_spawn: hook)
  end

  test "qualifies both configured path toolchain executables" do
    root = temp_dir!()
    cargo = fake_tool!(root, "cargo")
    rustc = fake_tool!(root, "rustc")

    config = %{
      backend: :canonical,
      toolchain: %{kind: :path, cargo: cargo, rustc: rustc, identity: "local"},
      rust_target: nil
    }

    assert {:ok, %{status: :verified}} = TargetInstaller.ensure(:desktop, config)

    admitted = cargo <> ".admitted"
    File.rename!(cargo, admitted)
    File.ln_s!(admitted, cargo)
    assert {:error, %{code: :tool_missing}} = TargetInstaller.ensure(:desktop, config)
  end

  test "external backends require no canonical Rust installation" do
    assert {:ok, %{status: :not_required}} =
             TargetInstaller.ensure(:web, %{backend: {:external, :admitted}})
  end

  defp fake_rustup!(root) do
    path = Path.join(root, "rustup")

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$*" >> "$REKINDLE_RUSTUP_LOG"
    """)

    File.chmod!(path, 0o700)
    path
  end

  defp fake_tool!(root, name) do
    path = Path.join(root, name)
    File.write!(path, "#!/bin/sh\nprintf '%s\\n' #{name}\n")
    File.chmod!(path, 0o700)
    path
  end

  defp temp_dir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "rekindle-target-installer-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
