defmodule Rekindle.CheckTest do
  use ExUnit.Case, async: false

  alias Rekindle.Check

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-check-#{System.unique_integer([:positive, :monotonic])}"
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

    previous = Application.get_env(:rekindle_check_test, Rekindle)

    Application.put_env(:rekindle_check_test, Rekindle,
      integration: :gpui,
      targets: [web: [], desktop: []]
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:rekindle_check_test, Rekindle, previous)
      else
        Application.delete_env(:rekindle_check_test, Rekindle)
      end

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "checks formatting, Clippy, and tests for every enabled target", %{root: root} do
    %{cargo: cargo, rustc: rustc, trace: trace} = fake_tools(root)
    test = self()

    assert :ok =
             Check.run(:rekindle_check_test,
               project_root: root,
               cargo: cargo,
               rustc: rustc,
               notify: fn status, label -> send(test, {status, label}) end
             )

    assert notifications() == [
             {:start, "Rust formatting"},
             {:ok, "Rust formatting"},
             {:start, "Web clippy"},
             {:ok, "Web clippy"},
             {:start, "Web tests"},
             {:ok, "Web tests"},
             {:start, "Desktop clippy"},
             {:ok, "Desktop clippy"},
             {:start, "Desktop tests"},
             {:ok, "Desktop tests"}
           ]

    commands = trace |> File.read!() |> String.split("\n", trim: true)
    assert [metadata, format, web_clippy, web_test, desktop_clippy, desktop_test] = commands
    assert metadata =~ "metadata --format-version 1 --no-deps"
    assert metadata =~ "--locked"
    assert format =~ "fmt --all"
    assert format =~ "-- --check"
    assert web_clippy =~ "clippy"
    assert web_clippy =~ "--bin web"
    assert web_clippy =~ "--target wasm32-unknown-unknown"
    assert web_clippy =~ "--features web"
    assert web_clippy =~ "-- -D warnings"
    assert web_test =~ "test"
    assert web_test =~ "--lib"
    assert web_test =~ "--features web"
    assert web_test =~ "--no-run"
    assert desktop_clippy =~ "--bin desktop"
    assert desktop_clippy =~ "--target x86_64-unknown-linux-gnu"
    assert desktop_clippy =~ "--features desktop"
    assert desktop_test =~ "--lib"
    assert desktop_test =~ "--features desktop"
    refute desktop_test =~ "--no-run"
  end

  test "stops at the first failed check with bounded Cargo output", %{root: root} do
    %{cargo: cargo, rustc: rustc, trace: trace} = fake_tools(root, fail: "clippy")

    assert {:error, %Rekindle.Cargo.Error{} = error} =
             Check.run(:rekindle_check_test,
               project_root: root,
               cargo: cargo,
               rustc: rustc
             )

    assert error.kind == :check_failed
    assert error.message == "Web clippy failed with status 17"
    assert error.output =~ "clippy failed"

    commands = trace |> File.read!() |> String.split("\n", trim: true)
    assert length(commands) == 3
    assert List.last(commands) =~ "clippy"
  end

  defp fake_tools(root, options \\ []) do
    cargo = Path.join(root, "cargo")
    rustc = Path.join(root, "rustc")
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
      case Keyword.get(options, :fail) do
        nil -> ""
        command -> ~s(if [ "$1" = "#{command}" ]; then echo "#{command} failed"; exit 17; fi)
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

    write_executable(
      rustc,
      """
      #!/bin/sh
      echo "rustc 1.88.0"
      echo "host: x86_64-unknown-linux-gnu"
      """
    )

    %{cargo: cargo, rustc: rustc, trace: trace}
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
