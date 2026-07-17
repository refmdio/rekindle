defmodule Rekindle.ShutdownStaticTest do
  use ExUnit.Case, async: true

  test "shutdown coordination delegates operating-system process control" do
    source = File.read!("lib/rekindle/shutdown.ex")

    refute source =~ "System.cmd"
    refute source =~ ":os.cmd"
    refute source =~ "Port."
    refute source =~ "SIGTERM"
    refute source =~ "SIGKILL"
    assert source =~ "ProcessRunner.begin_shutdown"
  end
end
