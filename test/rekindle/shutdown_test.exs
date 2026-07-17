defmodule Rekindle.ShutdownTest do
  use ExUnit.Case, async: true

  alias Rekindle.Shutdown
  alias Rekindle.Shutdown.Result

  test "an idle shutdown stops admission and returns the same clean result" do
    coordinator = start_supervised!({Shutdown, []})

    assert :ok = Shutdown.admit(coordinator)
    assert %Result{status: :clean, failures: []} = result = Shutdown.shutdown(coordinator)
    assert result == Shutdown.shutdown(coordinator)
    assert {:error, %{code: :cancelled}} = Shutdown.admit(coordinator)

    assert {:error, %{code: :cancelled}} =
             Shutdown.track(coordinator, :staging, cleanup: fn -> :ok end)
  end

  test "shutdown orders cancellation, client notification, release, and cleanup" do
    parent = self()
    coordinator = start_supervised!({Shutdown, []})

    for kind <- [:discovery, :build, :helper, :publish, :generic] do
      assert {:ok, _reference} =
               Shutdown.track(coordinator, kind,
                 cancel: callback(parent, {:cancel, kind}),
                 cleanup: callback(parent, {:cleanup, kind})
               )
    end

    for kind <- [:browser, :desktop] do
      assert {:ok, _reference} =
               Shutdown.track(coordinator, kind,
                 notify: callback(parent, {:notify, kind}),
                 cleanup: callback(parent, {:cleanup, kind})
               )
    end

    assert {:ok, _reference} =
             Shutdown.track(coordinator, :lease, release: callback(parent, {:release, :lease}))

    assert {:ok, _reference} =
             Shutdown.track(coordinator, :staging,
               cleanup: callback(parent, {:cleanup, :staging})
             )

    assert %Result{status: :clean} = Shutdown.shutdown(coordinator)
    messages = collect_messages(16)

    cancellation_positions = positions(messages, :cancel)
    notification_positions = positions(messages, :notify)
    release_positions = positions(messages, :release)
    cleanup_positions = positions(messages, :cleanup)

    assert length(cancellation_positions) == 5
    assert length(notification_positions) == 2
    assert length(release_positions) == 1
    assert length(cleanup_positions) == 8
    assert Enum.max(cancellation_positions) < Enum.min(notification_positions)
    assert Enum.max(notification_positions) < Enum.min(release_positions)
    assert Enum.max(release_positions) < Enum.min(cleanup_positions)
  end

  test "resource failures are sanitized, aggregated, and do not stop cleanup" do
    parent = self()
    coordinator = start_supervised!({Shutdown, []})

    assert {:ok, _reference} =
             Shutdown.track(coordinator, :generic,
               cancel: fn -> raise "private failure" end,
               cleanup: callback(parent, :cleanup_continued)
             )

    assert {:ok, _reference} =
             Shutdown.track(coordinator, :staging,
               cleanup: fn ->
                 {:error,
                  Rekindle.Failure.new!(
                    target: nil,
                    stage: :execution,
                    code: :cleanup_unconfirmed,
                    message: "Staging cleanup was not confirmed"
                  )}
               end
             )

    assert %Result{status: :uncertain, failures: failures} = Shutdown.shutdown(coordinator)
    assert_receive :cleanup_continued
    assert Enum.all?(failures, &match?(%Rekindle.Failure{}, &1))
    assert Enum.any?(failures, &(&1.code == :cleanup_unconfirmed))
    refute inspect(failures) =~ "private failure"
  end

  test "untrack is owner-scoped" do
    parent = self()
    coordinator = start_supervised!({Shutdown, []})

    owner =
      Task.async(fn ->
        {:ok, reference} =
          Shutdown.track(coordinator, :staging, cleanup: callback(parent, :owned_cleanup))

        send(parent, {:tracked, reference})
        Process.sleep(:infinity)
      end)

    assert_receive {:tracked, reference}
    assert :ok = Shutdown.untrack(coordinator, reference)
    assert %Result{status: :clean} = Shutdown.shutdown(coordinator)
    assert_receive :owned_cleanup
    Task.shutdown(owner, :brutal_kill)
  end

  test "invalid resources are rejected without stopping the coordinator" do
    coordinator = start_supervised!({Shutdown, []})

    assert {:error, %{code: :contract_violation}} =
             GenServer.call(coordinator, {:track, :staging, :not_a_keyword})

    assert :ok = Shutdown.admit(coordinator)
  end

  defp callback(parent, message) do
    fn ->
      send(parent, message)
      :ok
    end
  end

  defp collect_messages(count) do
    Enum.map(1..count, fn _ ->
      receive do
        message -> message
      after
        1_000 -> flunk("shutdown callback did not run")
      end
    end)
  end

  defp positions(messages, group) do
    messages
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{^group, _kind}, index} -> [index]
      {_message, _index} -> []
    end)
  end
end
