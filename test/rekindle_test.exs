defmodule RekindleTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Rekindle.Development

  test "starts the default Web development runtime" do
    root = temporary_client([:web])
    options = [otp_app: :demo, project_root: root]

    assert %{start: {Development, :start_link, [^options]}} =
             Supervisor.child_spec({Development, options}, [])

    Application.put_env(:demo, Rekindle, plugin: Rekindle.Plugin.GPUI, targets: [web: []])

    on_exit(fn ->
      Application.delete_env(:demo, Rekindle)
      File.rm_rf!(root)
    end)

    assert {:ok, pid} = start_supervised({Development, options})
    assert Process.alive?(pid)

    assert [{Rekindle.Development.Core, core, :supervisor, _modules}] =
             Supervisor.which_children(pid)

    assert length(Supervisor.which_children(core)) == 3

    assert %{web: _status} =
             status =
             Rekindle.Development.Builder.status(Rekindle.Development.Demo.Builder)

    assert Map.keys(status) == [:web]
  end

  test "adds the desktop launcher when desktop development is selected" do
    root = temporary_client([:web, :desktop])
    options = [otp_app: :combined_demo, project_root: root, targets: [:desktop]]

    Application.put_env(:combined_demo, Rekindle,
      plugin: Rekindle.Plugin.GPUI,
      targets: [web: [], desktop: []]
    )

    on_exit(fn ->
      Application.delete_env(:combined_demo, Rekindle)
      File.rm_rf!(root)
    end)

    supervisor = start_supervised!({Development, options})
    children = Supervisor.which_children(supervisor)

    assert Enum.any?(children, &(elem(&1, 0) == Rekindle.Desktop.Processes))
    assert Enum.any?(children, &(elem(&1, 0) == Rekindle.Desktop.Development))
    assert Enum.any?(children, &(elem(&1, 0) == Rekindle.Development.Core))
    assert length(children) == 3

    assert %{desktop: _status} =
             status =
             Rekindle.Development.Builder.status(Rekindle.Development.CombinedDemo.Builder)

    assert Map.keys(status) == [:desktop]

    stop_supervised(Development)
    refute Process.alive?(supervisor)
  end

  test "isolates a desktop launcher crash from the build core" do
    root = temporary_client([:web, :desktop])

    Application.put_env(:isolated_demo, Rekindle,
      plugin: Rekindle.Plugin.GPUI,
      targets: [web: [], desktop: []]
    )

    on_exit(fn ->
      Application.delete_env(:isolated_demo, Rekindle)
      File.rm_rf!(root)
    end)

    start_supervised!(
      {Development, otp_app: :isolated_demo, project_root: root, targets: [:desktop]}
    )

    builder = Process.whereis(Rekindle.Development.IsolatedDemo.Builder)
    desktop = Process.whereis(Rekindle.Development.IsolatedDemo.Desktop)
    builder_reference = Process.monitor(builder)
    desktop_reference = Process.monitor(desktop)

    capture_log(fn ->
      send(desktop, :unexpected)
      assert_receive {:DOWN, ^desktop_reference, :process, ^desktop, _reason}
    end)

    refute_receive {:DOWN, ^builder_reference, :process, ^builder, _reason}, 50
    assert Process.alive?(builder)
  end

  test "rejects development targets that are not enabled" do
    root = temporary_client([:web])
    Application.put_env(:web_demo, Rekindle, plugin: Rekindle.Plugin.GPUI, targets: [web: []])

    on_exit(fn ->
      Application.delete_env(:web_demo, Rekindle)
      File.rm_rf!(root)
    end)

    assert {:error,
            {{%Rekindle.Config.Error{kind: :invalid_development_targets}, _stacktrace}, _child}} =
             start_supervised(
               {Development, otp_app: :web_demo, project_root: root, targets: [:desktop]}
             )
  end

  defp temporary_client(targets) do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-supervisor-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "client/src/bin"))

    File.write!(Path.join(root, "client/Cargo.toml"), """
    [package]
    name = "client"
    version = "0.1.0"
    edition = "2024"
    """)

    Enum.each(targets, fn target ->
      File.write!(Path.join(root, "client/src/bin/#{target}.rs"), "fn main() {}\n")
    end)

    root
  end
end
