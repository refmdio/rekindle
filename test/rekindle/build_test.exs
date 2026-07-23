defmodule Rekindle.BuildTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    previous = Application.get_env(:rekindle_build_test, Rekindle)

    on_exit(fn ->
      if previous do
        Application.put_env(:rekindle_build_test, Rekindle, previous)
      else
        Application.delete_env(:rekindle_build_test, Rekindle)
      end
    end)

    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-build-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root}
  end

  test "requires an owning OTP application" do
    assert {:error, %Rekindle.Build.Error{kind: :missing_otp_app}} =
             Rekindle.build(:web)
  end

  test "rejects unknown and disabled targets before accessing an entry", %{root: root} do
    Application.put_env(:rekindle_build_test, Rekindle,
      integration: :gpui,
      targets: [desktop: []]
    )

    assert {:error, %Rekindle.Build.Error{kind: :unknown_target}} =
             Rekindle.build(:other, otp_app: :rekindle_build_test, project_root: root)

    assert {:error, %Rekindle.Build.Error{kind: :disabled_target}} =
             Rekindle.build(:web, otp_app: :rekindle_build_test, project_root: root)
  end

  test "rejects missing canonical entries before dispatch", %{root: root} do
    Application.put_env(:rekindle_build_test, Rekindle,
      integration: :gpui,
      targets: [desktop: []]
    )

    assert {:error, %Rekindle.Build.Error{kind: :missing_entry, message: message}} =
             Rekindle.build(:desktop,
               otp_app: :rekindle_build_test,
               project_root: root,
               profile: :release
             )

    assert message =~ "client/src/bin/desktop.rs"
  end

  test "returns a Cargo artifact without starting it", %{root: root} do
    File.cp_r!("test/fixtures/cargo_project", Path.join(root, "client"))

    Application.put_env(:rekindle_build_test, Rekindle,
      integration: :gpui,
      targets: [desktop: [profiles: [dev: "dev", release: "release"]]]
    )

    assert {:ok, %Rekindle.Build.Result{} = result} =
             Rekindle.build(:desktop,
               otp_app: :rekindle_build_test,
               project_root: root,
               profile: :release
             )

    assert result.target == :desktop
    assert result.profile == :release
    assert File.regular?(result.artifact)
    assert result.artifact =~ "/release/desktop"
  end

  test "Mix build renders bounded Rust diagnostics", %{root: root} do
    File.cp_r!("test/fixtures/cargo_project", Path.join(root, "client"))
    marker = "\n[diagnostics truncated]"
    prefix_size = 64_000 - byte_size(marker)
    alignment = rem(prefix_size - 1, 4)
    assert rem(prefix_size - alignment, 4) == 1
    oversized = String.duplicate("a", alignment) <> String.duplicate("💥", 30_000)
    fake_bin = fake_diagnostic_cargo(root, oversized)
    previous_path = System.fetch_env!("PATH")

    previous = Application.get_env(:rekindle, Rekindle)

    on_exit(fn ->
      System.put_env("PATH", previous_path)

      if previous do
        Application.put_env(:rekindle, Rekindle, previous)
      else
        Application.delete_env(:rekindle, Rekindle)
      end
    end)

    Application.put_env(:rekindle, Rekindle,
      integration: :gpui,
      targets: [desktop: []]
    )

    System.put_env("PATH", fake_bin <> ":" <> previous_path)

    output =
      File.cd!(root, fn ->
        Mix.Task.reenable("rekindle.build")

        capture_io(:stderr, fn ->
          assert_raise Mix.Error, "cargo build failed with status 1", fn ->
            Mix.Tasks.Rekindle.Build.run(["desktop"])
          end
        end)
      end)

    assert output =~ "💥"
    assert output =~ "[diagnostics truncated]"
    assert String.valid?(output)
    assert byte_size(output) == 64_000
  end

  defp fake_diagnostic_cargo(root, rendered) do
    bin = Path.join(root, "fake-bin")
    path = Path.join(bin, "cargo")
    package_id = "fixture_ui 0.1.0"

    metadata =
      Jason.encode!(%{
        "packages" => [
          %{
            "id" => package_id,
            "name" => "fixture_ui",
            "manifest_path" => Path.join(root, "client/Cargo.toml"),
            "targets" => [
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

    diagnostic =
      Jason.encode!(%{
        "reason" => "compiler-message",
        "message" => %{
          "level" => "error",
          "message" => "oversized diagnostic",
          "rendered" => rendered,
          "spans" => []
        }
      })

    File.mkdir_p!(bin)

    File.write!(
      path,
      """
      #!/bin/sh
      if [ "$1" = "metadata" ]; then
        printf '%s\\n' '#{metadata}'
        exit 0
      fi
      printf '%s\\n' '#{diagnostic}'
      exit 1
      """
    )

    File.chmod!(path, 0o755)
    bin
  end
end
