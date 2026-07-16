defmodule Rekindle.ApplicationTest do
  use ExUnit.Case, async: false

  alias Rekindle.RuntimeState

  @otp_app :rekindle_lifecycle_test

  setup do
    previous_build = Application.get_env(@otp_app, :rekindle_build)
    previous_dev = Application.get_env(@otp_app, :rekindle_dev)

    Application.put_env(@otp_app, :rekindle_build, build_config())
    Application.put_env(@otp_app, :rekindle_dev, dev_config())

    on_exit(fn ->
      restore(:rekindle_build, previous_build)
      restore(:rekindle_dev, previous_dev)
    end)

    :ok
  end

  test "publishes the exact stable child specification" do
    spec = Rekindle.child_spec(otp_app: @otp_app, name: :lifecycle_project)

    assert spec == %{
             id: {Rekindle, @otp_app},
             start:
               {Rekindle.ProjectSupervisor, :start_link,
                [[otp_app: @otp_app, name: :lifecycle_project]]},
             restart: :permanent,
             shutdown: 30_000,
             type: :supervisor
           }

    assert_raise ArgumentError, fn -> Rekindle.child_spec(otp_app: @otp_app) end

    assert_raise ArgumentError, fn ->
      Rekindle.child_spec(otp_app: @otp_app, name: :x, extra: true)
    end
  end

  test "starts one idle owner and stops without external work" do
    ports_before = MapSet.new(Port.list())
    name = unique_name(:project)
    assert {:ok, supervisor} = start_supervised({Rekindle, otp_app: @otp_app, name: name})

    assert {:ok,
            %{
              otp_app: @otp_app,
              status: :idle,
              target_count: 0,
              owned_process_count: 0
            }} = RuntimeState.snapshot(File.cwd!())

    assert Process.alive?(supervisor)
    assert ports_before == MapSet.new(Port.list())
  end

  test "rejects a duplicate normalized project even under another supervisor name" do
    first = unique_name(:first)
    second = unique_name(:second)

    assert {:ok, _pid} = start_supervised({Rekindle, otp_app: @otp_app, name: first})

    assert {:error, {:already_started, _pid}} =
             start_supervised({Rekindle, otp_app: @otp_app, name: second})
  end

  test "fails before runtime ownership when configuration is invalid" do
    Application.put_env(@otp_app, :rekindle_build, schema: 2)

    assert {:error, {:configuration, errors}} =
             Rekindle.ProjectSupervisor.start_link(
               otp_app: @otp_app,
               name: unique_name(:invalid)
             )

    assert Enum.any?(errors, &(&1.code in [:config_invalid, :path_invalid]))
    assert :none = RuntimeState.snapshot(File.cwd!())
  end

  defp build_config do
    [
      schema: 1,
      client: "client",
      targets: [
        desktop: [
          package: "lifecycle_ui",
          binary: "lifecycle",
          toolchain: [kind: :rustup, name: "1.95.0"],
          features: ["desktop"],
          projection: [mode: :directory, root: "dist/rekindle/desktop"]
        ]
      ]
    ]
  end

  defp dev_config, do: [schema: 1, enabled: true, targets: [:desktop]]

  defp unique_name(prefix),
    do: Module.concat(__MODULE__, "#{prefix}_#{System.unique_integer([:positive])}")

  defp restore(key, nil), do: Application.delete_env(@otp_app, key)
  defp restore(key, value), do: Application.put_env(@otp_app, key, value)
end
