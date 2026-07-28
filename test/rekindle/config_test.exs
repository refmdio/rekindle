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

  test "loads fixed project paths and configured targets" do
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
      ]
    )

    assert {:ok, project} = Config.load(:rekindle_config_test, project_root: root)
    assert project.client_root == Path.join(root, "client")
    assert project.public_dir == Path.join(root, "priv/static")
    assert project.integration == :egui

    assert %Config.Target{
             name: :web,
             entry: "client/src/bin/web.rs",
             package: "sample_ui",
             binary: "browser",
             features: ["web"],
             profiles: %{dev: "fast", release: "shipping"}
           } = project.targets.web
  end

  test "uses the target name as the default Cargo feature" do
    Application.put_env(:rekindle_config_test, Rekindle,
      integration: :gpui,
      targets: [web: [], desktop: []]
    )

    assert {:ok, project} = Config.load(:rekindle_config_test)
    assert project.targets.web.features == ["web"]
    assert project.targets.desktop.features == ["desktop"]
  end

  test "preserves an explicitly empty Cargo feature list" do
    Application.put_env(:rekindle_config_test, Rekindle,
      integration: :gpui,
      targets: [desktop: [features: []]]
    )

    assert {:ok, project} = Config.load(:rekindle_config_test)
    assert project.targets.desktop.features == []
  end

  test "rejects unknown configuration values" do
    Application.put_env(:rekindle_config_test, Rekindle,
      integration: :other,
      targets: [web: []]
    )

    assert {:error, %Config.Error{kind: :invalid_integration}} =
             Config.load(:rekindle_config_test)

    Application.put_env(:rekindle_config_test, Rekindle,
      integration: :gpui,
      targets: [web: []],
      public_dir: "web/static"
    )

    assert {:error, %Config.Error{kind: :unknown_key}} =
             Config.load(:rekindle_config_test)
  end

  test "requires an integration and at least one target" do
    assert {:error, %Config.Error{kind: :missing_configuration}} =
             Config.load(:rekindle_config_test)

    Application.put_env(:rekindle_config_test, Rekindle, integration: :gpui, targets: [])

    assert {:error, %Config.Error{kind: :missing_targets}} =
             Config.load(:rekindle_config_test)
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
