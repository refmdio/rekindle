defmodule Rekindle.TestTest do
  use ExUnit.Case, async: false

  alias Rekindle.Test, as: RustTest

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    client = Path.join(root, "client")
    File.mkdir_p!(root)
    File.cp_r!("test/fixtures/cargo_project", client)
    File.write!(Path.join(client, "src/lib.rs"), "pub fn shared() {}\n")

    manifest = Path.join(client, "Cargo.toml")

    File.write!(
      manifest,
      File.read!(manifest) <>
        """

        [features]
        web = []
        desktop = []
        """
    )

    previous = Application.get_env(:rekindle_test_test, Rekindle)

    Application.put_env(:rekindle_test_test, Rekindle,
      plugin: Rekindle.Plugin.GPUI,
      targets: [web: [], desktop: []]
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:rekindle_test_test, Rekindle, previous)
      else
        Application.delete_env(:rekindle_test_test, Rekindle)
      end

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "runs the configured Cargo package once with standard test selection", %{root: root} do
    %{cargo: cargo, trace: trace} = fake_cargo(root)
    test = self()

    assert :ok =
             RustTest.run(:rekindle_test_test,
               project_root: root,
               cargo: cargo,
               notify: fn status, label -> send(test, {status, label}) end
             )

    assert notifications() == [
             {:start, "Rust tests for fixture_ui"},
             {:ok, "Rust tests for fixture_ui"}
           ]

    assert [metadata, cargo_test] =
             trace |> File.read!() |> String.split("\n", trim: true)

    assert metadata =~ "metadata --format-version 1 --no-deps"
    assert metadata =~ "--locked"
    assert cargo_test =~ "test --manifest-path"
    assert cargo_test =~ "--package fixture_ui"
    assert cargo_test =~ "--locked"
    refute cargo_test =~ "--lib"
    refute cargo_test =~ "--target"
    refute cargo_test =~ "--features"
  end

  test "reports Cargo test output on failure", %{root: root} do
    %{cargo: cargo} = fake_cargo(root, fail: true)

    assert {:error, %Rekindle.Cargo.Error{} = error} =
             RustTest.run(:rekindle_test_test, project_root: root, cargo: cargo)

    assert error.kind == :test_failed
    assert error.message == "Rust tests for fixture_ui failed with status 17"
    assert error.output =~ "Rust test failed"

    assert_raise Rekindle.Cargo.Error, ~r/Rust test failed/, fn ->
      RustTest.run!(:rekindle_test_test, project_root: root, cargo: cargo)
    end
  end

  defp fake_cargo(root, options \\ []) do
    cargo = Path.join(root, "cargo")
    trace = Path.join(root, "cargo-trace")
    manifest = Path.join(root, "client/Cargo.toml")
    package_id = "fixture_ui 0.1.0"

    metadata =
      Jason.encode!(%{
        "packages" => [
          %{
            "id" => package_id,
            "name" => "fixture_ui",
            "manifest_path" => manifest,
            "targets" => [
              %{
                "name" => "fixture_ui",
                "kind" => ["lib"],
                "src_path" => Path.join(root, "client/src/lib.rs")
              },
              %{
                "name" => "web",
                "kind" => ["bin"],
                "src_path" => Path.join(root, "client/src/bin/web.rs")
              },
              %{
                "name" => "desktop",
                "kind" => ["bin"],
                "src_path" => Path.join(root, "client/src/bin/desktop.rs")
              }
            ],
            "dependencies" => [%{"name" => "gpui"}]
          }
        ],
        "workspace_members" => [package_id],
        "target_directory" => Path.join(root, "client/target")
      })

    failure =
      if Keyword.get(options, :fail, false) do
        ~s(if [ "$1" = "test" ]; then echo "Rust test failed"; exit 17; fi)
      else
        ""
      end

    write_executable(
      cargo,
      """
      #!/bin/sh
      printf '%s\\n' "$*" >> "#{trace}"
      if [ "$1" = "metadata" ]; then
        printf '%s\\n' '#{metadata}'
        exit 0
      fi
      #{failure}
      exit 0
      """
    )

    %{cargo: cargo, trace: trace}
  end

  defp notifications(acc \\ []) do
    receive do
      notification -> notifications([notification | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end
end
