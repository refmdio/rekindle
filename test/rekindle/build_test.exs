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
    oversized = String.duplicate("界", 30_000)

    File.write!(
      Path.join(root, "client/src/bin/desktop.rs"),
      "compile_error!(#{inspect(oversized)});"
    )

    previous = Application.get_env(:rekindle, Rekindle)

    on_exit(fn ->
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

    output =
      File.cd!(root, fn ->
        Mix.Task.reenable("rekindle.build")

        capture_io(:stderr, fn ->
          assert_raise Mix.Error, "cargo build failed with status 101", fn ->
            Mix.Tasks.Rekindle.Build.run(["desktop"])
          end
        end)
      end)

    assert output =~ "界"
    assert output =~ "[diagnostics truncated]"
    assert String.valid?(output)
    assert byte_size(output) <= 64_001
  end
end
