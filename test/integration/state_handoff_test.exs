defmodule Rekindle.StateHandoffIntegrationTest do
  use ExUnit.Case, async: false

  @manifest "crates/rekindle-client/Cargo.toml"

  test "portable handoff semantics compile and pass for native and Web targets" do
    target_dir =
      Path.join(
        System.tmp_dir!(),
        "rekindle-state-handoff-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf(target_dir) end)

    {rustc, 0} = System.cmd("rustup", ["which", "--toolchain", "1.95.0", "rustc"])
    environment = [{"CARGO_TARGET_DIR", target_dir}, {"RUSTC", String.trim(rustc)}]

    assert_cargo(
      [
        "test",
        "--manifest-path",
        @manifest,
        "--lib",
        "--no-default-features",
        "--features",
        "state-handoff",
        "--offline"
      ],
      environment
    )

    for {target, features} <- [
          {"x86_64-unknown-linux-gnu", "desktop,state-handoff"},
          {"wasm32-unknown-unknown", "web,state-handoff"}
        ] do
      assert_cargo(
        [
          "check",
          "--manifest-path",
          @manifest,
          "--lib",
          "--target",
          target,
          "--no-default-features",
          "--features",
          features,
          "--offline"
        ],
        environment
      )
    end
  end

  defp assert_cargo(arguments, environment) do
    {output, status} =
      System.cmd("rustup", ["run", "1.95.0", "cargo" | arguments],
        cd: File.cwd!(),
        env: environment,
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
