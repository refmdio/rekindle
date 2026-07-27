defmodule RekindleTest do
  use ExUnit.Case, async: false

  test "starts the development runtime as a supervision child" do
    root = temporary_client([:web])
    options = [otp_app: :demo, endpoint: DemoWeb.Endpoint, project_root: root]

    assert %{start: {Rekindle, :start_link, [^options]}} =
             Supervisor.child_spec({Rekindle, options}, [])

    Application.put_env(:demo, DemoWeb.Endpoint, code_reloader: true)
    Application.put_env(:demo, Rekindle, integration: :gpui, targets: [web: []])

    on_exit(fn ->
      Application.delete_env(:demo, DemoWeb.Endpoint)
      Application.delete_env(:demo, Rekindle)
      File.rm_rf!(root)
    end)

    assert {:ok, pid} = start_supervised({Rekindle, options})
    assert Process.alive?(pid)
    assert length(Supervisor.which_children(pid)) == 3
  end

  test "adds the desktop launcher when desktop is enabled" do
    root = temporary_client([:web, :desktop])
    options = [otp_app: :combined_demo, endpoint: CombinedDemoWeb.Endpoint, project_root: root]

    Application.put_env(:combined_demo, CombinedDemoWeb.Endpoint, code_reloader: true)

    Application.put_env(:combined_demo, Rekindle,
      integration: :gpui,
      targets: [web: [], desktop: []]
    )

    on_exit(fn ->
      Application.delete_env(:combined_demo, CombinedDemoWeb.Endpoint)
      Application.delete_env(:combined_demo, Rekindle)
      File.rm_rf!(root)
    end)

    supervisor = start_supervised!({Rekindle, options})
    children = Supervisor.which_children(supervisor)

    assert Enum.any?(children, &(elem(&1, 0) == Rekindle.Desktop.Processes))
    assert Enum.any?(children, &(elem(&1, 0) == Rekindle.Desktop.Development))
    assert length(children) == 5

    stop_supervised(Rekindle)
    refute Process.alive?(supervisor)
  end

  test "does not start outside code-reloading environments" do
    Application.put_env(:production_demo, Unrelated, code_reloader: true)
    on_exit(fn -> Application.delete_env(:production_demo, Unrelated) end)

    assert :ignore =
             Rekindle.start_link(
               otp_app: :production_demo,
               endpoint: ProductionDemoWeb.Endpoint
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
