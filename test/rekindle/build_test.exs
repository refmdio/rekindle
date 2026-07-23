defmodule Rekindle.BuildTest do
  use ExUnit.Case, async: false

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
end
