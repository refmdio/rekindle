defmodule Rekindle.ConfigTest do
  use ExUnit.Case, async: false

  alias Rekindle.Config

  setup do
    previous = Application.get_env(:rekindle_config_test, Rekindle)

    on_exit(fn ->
      if previous do
        Application.put_env(:rekindle_config_test, Rekindle, previous)
      else
        Application.delete_env(:rekindle_config_test, Rekindle)
      end
    end)

    :ok
  end

  test "loads the fixed client root and configured targets" do
    root = tmp_dir()

    Application.put_env(:rekindle_config_test, Rekindle,
      integration: :egui,
      targets: [
        web: [
          package: "sample_ui",
          binary: "browser",
          features: ["web"],
          profiles: [dev: "fast", release: "shipping"]
        ]
      ],
      public_dir: "priv/static"
    )

    assert {:ok, project} = Config.load(:rekindle_config_test, project_root: root)
    assert project.client_root == Path.join(root, "client")
    assert project.integration == :egui
    assert project.public_dir == Path.join(root, "priv/static")

    assert %Config.Target{
             name: :web,
             entry: "client/src/bin/web.rs",
             package: "sample_ui",
             binary: "browser",
             features: ["web"],
             profiles: %{dev: "fast", release: "shipping"}
           } = project.targets.web
  end

  test "rejects unknown configuration and paths outside the project" do
    Application.put_env(:rekindle_config_test, Rekindle,
      integration: :other,
      targets: [web: []]
    )

    assert {:error, %Config.Error{kind: :invalid_integration}} =
             Config.load(:rekindle_config_test)

    Application.put_env(:rekindle_config_test, Rekindle,
      integration: :gpui,
      targets: [web: []],
      public_dir: "../static"
    )

    assert {:error, %Config.Error{kind: :invalid_path}} =
             Config.load(:rekindle_config_test)

    Application.put_env(:rekindle_config_test, Rekindle,
      integration: :gpui,
      targets: [web: []],
      command: "cargo build"
    )

    assert {:error, %Config.Error{kind: :unknown_key}} =
             Config.load(:rekindle_config_test)
  end

  test "requires an explicit integration and at least one target" do
    assert {:error, %Config.Error{kind: :missing_configuration}} =
             Config.load(:rekindle_config_test)

    Application.put_env(:rekindle_config_test, Rekindle, integration: :gpui, targets: [])

    assert {:error, %Config.Error{kind: :missing_targets}} =
             Config.load(:rekindle_config_test)
  end

  test "rejects configured and fixed paths that escape through symbolic links" do
    root = tmp_dir()
    outside = tmp_dir()

    File.ln_s!(outside, Path.join(root, "static-link"))

    Application.put_env(:rekindle_config_test, Rekindle,
      integration: :gpui,
      targets: [web: []],
      public_dir: "static-link"
    )

    assert {:error, %Config.Error{kind: :invalid_path}} =
             Config.load(:rekindle_config_test, project_root: root)

    File.ln_s!(outside, Path.join(root, "client"))

    Application.put_env(:rekindle_config_test, Rekindle,
      integration: :gpui,
      targets: [web: []]
    )

    assert {:error, %Config.Error{kind: :invalid_path}} =
             Config.load(:rekindle_config_test, project_root: root)
  end

  test "resolves symbolic links that remain inside the project" do
    root = tmp_dir()
    File.mkdir_p!(Path.join(root, "priv/static"))
    File.ln_s!("priv/static", Path.join(root, "static-link"))

    Application.put_env(:rekindle_config_test, Rekindle,
      integration: :gpui,
      targets: [web: []],
      public_dir: "static-link"
    )

    assert {:ok, project} = Config.load(:rekindle_config_test, project_root: root)
    assert project.public_dir == Path.join(root, "priv/static")
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "rekindle-config-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
