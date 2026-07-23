defmodule RekindleTest do
  use ExUnit.Case, async: true

  test "is a valid supervision child" do
    assert %{start: {Rekindle, :start_link, [[otp_app: :demo]]}} =
             Supervisor.child_spec({Rekindle, otp_app: :demo}, [])

    Application.put_env(:demo, DemoWeb.Endpoint, code_reloader: true)
    on_exit(fn -> Application.delete_env(:demo, DemoWeb.Endpoint) end)

    assert {:ok, pid} = start_supervised({Rekindle, otp_app: :demo})
    assert Process.alive?(pid)
  end

  test "does not start outside code-reloading environments" do
    assert :ignore = Rekindle.start_link(otp_app: :production_demo)
  end
end
