defmodule Rekindle.QualifiedPathTest do
  use ExUnit.Case, async: false

  alias Rekindle.QualifiedPath

  test "stored authority rejects access escalation and expires with its scope" do
    parent = self()
    path = Path.join(System.tmp_dir!(), "qualified-path")

    handle =
      QualifiedPath.with_scope(fn ->
        handle = QualifiedPath.issue(path, :read)
        forged = %{handle | access: :read_write}

        assert {:ok, ^path} = QualifiedPath.resolve(handle, :read)
        assert :error = QualifiedPath.resolve(handle, :read_write)
        assert :error = QualifiedPath.resolve(forged, :read_write)
        send(parent, {:scope_size, QualifiedPath.authority_size()})
        handle
      end)

    assert_receive {:scope_size, size} when size > 0
    assert :error = QualifiedPath.resolve(handle, :read)
  end

  test "authority storage is private and remains bounded across executions" do
    baseline = QualifiedPath.authority_size()
    assert :undefined == :ets.whereis(QualifiedPath)

    for index <- 1..100 do
      QualifiedPath.with_scope(fn ->
        handle = QualifiedPath.issue("relative/#{index}", :read_write)
        assert {:ok, _path} = QualifiedPath.resolve(handle, :read_write)
      end)
    end

    assert QualifiedPath.authority_size() == baseline
  end

  test "owner death revokes every token in an abandoned scope" do
    parent = self()

    owner =
      spawn(fn ->
        QualifiedPath.with_scope(fn ->
          handle = QualifiedPath.issue("abandoned", :read)
          send(parent, {:handle, handle})
          Process.sleep(:infinity)
        end)
      end)

    assert_receive {:handle, handle}
    assert {:ok, _path} = QualifiedPath.resolve(handle, :read)

    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    eventually(fn -> QualifiedPath.resolve(handle, :read) == :error end)
  end

  defp eventually(assertion, attempts \\ 20)

  defp eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(10)
      eventually(assertion, attempts - 1)
    end
  end

  defp eventually(_assertion, 0), do: flunk("condition did not become true")
end
