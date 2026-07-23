defmodule RekindleTest do
  use ExUnit.Case, async: false

  test "is a valid supervision child" do
    root = temporary_client()
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

  test "does not start outside code-reloading environments" do
    Application.put_env(:production_demo, Unrelated, code_reloader: true)
    on_exit(fn -> Application.delete_env(:production_demo, Unrelated) end)

    assert :ignore =
             Rekindle.start_link(
               otp_app: :production_demo,
               endpoint: ProductionDemoWeb.Endpoint
             )
  end

  defp temporary_client do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-supervisor-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "client/src/bin"))
    File.write!(Path.join(root, "client/src/bin/web.rs"), "fn main() {}\n")
    root
  end
end
