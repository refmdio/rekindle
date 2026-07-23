defmodule RekindleTest do
  use ExUnit.Case, async: true

  test "is a valid supervision child" do
    assert %{start: {Rekindle, :start_link, [[otp_app: :demo]]}} =
             Supervisor.child_spec({Rekindle, otp_app: :demo}, [])

    assert {:ok, pid} = start_supervised({Rekindle, otp_app: :demo})
    assert Process.alive?(pid)
  end
end
