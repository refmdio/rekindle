defmodule RekindleTest do
  use ExUnit.Case, async: true

  test "is a valid supervision child" do
    options = [otp_app: :demo, endpoint: DemoWeb.Endpoint]

    assert %{start: {Rekindle, :start_link, [^options]}} =
             Supervisor.child_spec({Rekindle, options}, [])

    Application.put_env(:demo, DemoWeb.Endpoint, code_reloader: true)
    on_exit(fn -> Application.delete_env(:demo, DemoWeb.Endpoint) end)

    assert {:ok, pid} = start_supervised({Rekindle, options})
    assert Process.alive?(pid)
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
end
