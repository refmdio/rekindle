defmodule Rekindle.EventTest do
  use ExUnit.Case, async: false

  alias Rekindle.{BuildResult, Diagnostic, Event, EventBus, GenerationRef}

  @session String.duplicate("1", 32)
  @generation String.duplicate("2", 32)
  @digest String.duplicate("a", 64)

  test "generation and build results are closed typed projections" do
    assert {:ok, generation} =
             GenerationRef.new(
               target: :web,
               generation_id: @generation,
               artifact_id: @digest,
               profile: "dev",
               manifest_digest: @digest
             )

    assert {:ok, diagnostic} =
             Diagnostic.new(
               target: :web,
               stage: :execution,
               severity: :warning,
               code: :cargo_compiler,
               message: "warning"
             )

    assert {:ok, result} =
             BuildResult.new(
               target: :web,
               mode: :dev,
               source_revision: 4,
               build_key: @digest,
               generation: generation,
               duration_ms: 25,
               diagnostics: [diagnostic]
             )

    assert BuildResult.to_map(result) == %{
             "contract_version" => 1,
             "target" => "web",
             "mode" => "dev",
             "source_revision" => 4,
             "build_key" => @digest,
             "generation" => GenerationRef.to_map(generation),
             "duration_ms" => 25,
             "diagnostics" => [Diagnostic.to_map(diagnostic)]
           }

    assert {:error, %{code: :contract_violation}} =
             BuildResult.new(
               target: :desktop,
               mode: :dev,
               source_revision: 4,
               build_key: @digest,
               generation: generation,
               duration_ms: 25,
               diagnostics: []
             )
  end

  test "every event variant enforces its root nullability and exact payload" do
    fixtures = fixtures()

    for {type, roots, payload} <- fixtures do
      attributes =
        roots
        |> Map.merge(%{
          project_session: @session,
          sequence: 0,
          type: type,
          payload: payload
        })

      event =
        case Event.new(attributes) do
          {:ok, event} -> event
          other -> flunk("#{type} was rejected: #{inspect(other)}")
        end

      encoded = Event.to_map(event)
      assert encoded["contract_version"] == 1
      assert encoded["type"] == Atom.to_string(type)
      assert is_map(encoded["payload"])

      assert {:error, %{code: :contract_violation}} =
               attributes |> Map.put(:unexpected, true) |> Event.new()

      assert {:error, %{code: :contract_violation}} =
               attributes |> Map.put(:contract_version, 2) |> Event.new()
    end

    {type, roots, payload} = Enum.find(fixtures, &(elem(&1, 0) == :build_started))

    assert {:error, %{code: :contract_violation}} =
             Event.new(
               roots
               |> Map.merge(%{
                 project_session: @session,
                 sequence: 0,
                 type: type,
                 payload: %{payload | stages: Enum.reverse(payload.stages)}
               })
             )

    assert {:error, %{code: :contract_violation}} =
             Event.new(
               project_session: @session,
               sequence: 0,
               target: nil,
               source_revision: 1,
               generation_id: nil,
               type: :build_failed,
               payload: %{failure_code: :cargo_failed, diagnostic_count: 1}
             )
  end

  test "event bus orders delivery, rejects duplicate terminals, and enforces progress monotonicity" do
    bus = start_supervised!({EventBus, otp_app: :event_test, project_session: @session})

    assert {:ok, subscription} = Rekindle.subscribe(:event_test)

    assert {:ok, first} = EventBus.emit(bus, event_attributes(:build_started, 1))
    assert first.sequence == 0
    assert_receive {:rekindle_event, ^subscription, ^first}

    assert {:ok, progress} = EventBus.emit(bus, event_attributes(:stage_progress, 1, 5))
    assert progress.sequence == 1

    assert {:error, %{code: :unexpected_state}} =
             EventBus.emit(bus, event_attributes(:stage_progress, 1, 4))

    assert {:ok, terminal} = EventBus.emit(bus, event_attributes(:build_failed, 1))
    assert terminal.sequence == 2

    assert {:error, %{code: :unexpected_state}} =
             EventBus.emit(bus, event_attributes(:build_cancelled, 1))

    assert {:ok, published} =
             EventBus.emit(bus, %{
               target: :web,
               source_revision: 1,
               generation_id: @generation,
               type: :generation_published,
               payload: %{artifact_id: @digest, manifest_digest: @digest}
             })

    assert published.sequence == 3
    assert :ok = Rekindle.unsubscribe(:event_test, subscription)
  end

  test "event ordering state is bounded across revisions and independent targets" do
    bus =
      start_supervised!({EventBus, otp_app: :bounded_event_test, project_session: @session})

    assert {:ok, subscription} = EventBus.subscribe(bus)

    for revision <- 1..128, target <- [:web, :desktop] do
      stage = if target == :web, do: :cargo_web, else: :cargo_desktop

      assert {:ok, _event} =
               EventBus.emit(
                 bus,
                 event_attributes(:stage_progress, target, revision, stage, 1)
               )

      assert {:ok, _event} =
               EventBus.emit(bus, event_attributes(:build_failed, target, revision))
    end

    assert_receive {:rekindle_event, ^subscription,
                    %Event{target: :web, source_revision: 128, type: :build_failed}}

    assert_receive {:rekindle_event, ^subscription,
                    %Event{target: :desktop, source_revision: 128, type: :build_failed}}

    state = :sys.get_state(bus)

    assert state.ordering == %{
             web: %{revision: 128, terminal?: true, progress: %{}},
             desktop: %{revision: 128, terminal?: true, progress: %{}}
           }

    assert {:error, %{code: :unexpected_state}} =
             EventBus.emit(bus, event_attributes(:build_started, :web, 127))

    assert {:error, %{code: :unexpected_state}} =
             EventBus.emit(
               bus,
               event_attributes(:stage_progress, :web, 127, :cargo_web, 2)
             )

    assert {:error, %{code: :unexpected_state}} =
             EventBus.emit(bus, event_attributes(:build_failed, :web, 128))

    assert {:error, %{code: :unexpected_state}} =
             EventBus.emit(bus, event_attributes(:build_cancelled, :web, 128))

    assert {:ok, _event} =
             EventBus.emit(bus, event_attributes(:build_started, :web, 129))

    assert {:ok, _event} =
             EventBus.emit(
               bus,
               event_attributes(:stage_progress, :web, 129, :cargo_web, 5)
             )

    assert {:ok, _event} =
             EventBus.emit(
               bus,
               event_attributes(:stage_progress, :web, 129, :bindgen_web, 7)
             )

    assert {:error, %{code: :unexpected_state}} =
             EventBus.emit(
               bus,
               event_attributes(:stage_progress, :web, 129, :cargo_web, 4)
             )

    assert {:error, %{code: :unexpected_state}} =
             EventBus.emit(
               bus,
               event_attributes(:stage_progress, :web, 129, :bindgen_web, 6)
             )

    state = :sys.get_state(bus)
    assert map_size(state.ordering) == 2
    assert state.ordering.web.progress == %{cargo_web: 5, bindgen_web: 7}
    assert state.ordering.desktop == %{revision: 128, terminal?: true, progress: %{}}

    assert {:ok, _event} =
             EventBus.emit(bus, event_attributes(:build_cancelled, :web, 129))

    assert :sys.get_state(bus).ordering.web == %{
             revision: 129,
             terminal?: true,
             progress: %{}
           }

    assert {:ok, published} =
             EventBus.emit(bus, %{
               target: :web,
               source_revision: 1,
               generation_id: @generation,
               type: :generation_published,
               payload: %{artifact_id: @digest, manifest_digest: @digest}
             })

    assert_receive {:rekindle_event, ^subscription, ^published}
    assert map_size(:sys.get_state(bus).ordering) == 2
  end

  test "slow subscribers are evicted at the configured watermark" do
    bus = start_supervised!({EventBus, otp_app: :slow_event_test, project_session: @session})

    parent = self()

    subscriber =
      spawn(fn ->
        {:ok, reference} = EventBus.subscribe(bus)
        send(parent, {:subscribed, reference})

        receive do
          :release -> :ok
        end
      end)

    assert_receive {:subscribed, reference}
    for queued <- 1..1_024, do: send(subscriber, {:already_queued, queued})
    assert {:ok, _event} = EventBus.emit(bus, event_attributes(:build_started, 1))
    send(subscriber, :release)
    refute_receive {:rekindle_event, ^reference, _event}
  end

  test "typed results are projected by the shared command boundary" do
    {:ok, generation} =
      GenerationRef.new(
        target: :web,
        generation_id: @generation,
        artifact_id: @digest,
        profile: "dev",
        manifest_digest: @digest
      )

    {:ok, result} =
      BuildResult.new(
        target: :web,
        mode: :dev,
        source_revision: 4,
        build_key: @digest,
        generation: generation,
        duration_ms: 25,
        diagnostics: []
      )

    grammar = [switches: [json: :boolean], positionals: 0]

    outcome =
      Rekindle.Command.run("rekindle.example", ["--json"], grammar, fn _ -> {:ok, result} end)

    assert outcome.exit_status == 0
    assert outcome.stderr == ""
    assert Jason.decode!(outcome.stdout)["result"] == BuildResult.to_map(result)

    assert outcome.stdout ==
             Rekindle.CanonicalValue.encode!(Jason.decode!(outcome.stdout)) <> "\n"
  end

  test "build results reject a structurally modified generation" do
    {:ok, generation} =
      GenerationRef.new(
        target: :web,
        generation_id: @generation,
        artifact_id: @digest,
        profile: "dev",
        manifest_digest: @digest
      )

    assert {:error, %{code: :contract_violation}} =
             BuildResult.new(
               target: :web,
               mode: :dev,
               source_revision: 4,
               build_key: @digest,
               generation: %{generation | contract_version: 2},
               duration_ms: 25,
               diagnostics: []
             )
  end

  test "events expose a stable telemetry prefix without payload bytes" do
    handler = "rekindle-event-test-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:rekindle, :event, :build_started],
        fn name, measurements, metadata, _config ->
          send(parent, {:telemetry_event, name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    bus = start_supervised!({EventBus, otp_app: :telemetry_event_test, project_session: @session})
    assert {:ok, _event} = EventBus.emit(bus, event_attributes(:build_started, 1))

    assert_receive {:telemetry_event, [:rekindle, :event, :build_started], %{sequence: 0},
                    metadata}

    assert Map.keys(metadata) |> Enum.sort() ==
             ~w[generation_id project_session source_revision target type]a |> Enum.sort()

    refute Map.has_key?(metadata, :payload)
  end

  defp fixtures do
    none = %{target: nil, source_revision: nil, generation_id: nil}
    build = %{target: :web, source_revision: 1, generation_id: nil}
    generated = %{target: :web, source_revision: 1, generation_id: @generation}

    [
      {:configuration_rejected, none, %{failure_code: :config_invalid, diagnostic_count: 1}},
      {:session_ready, none, %{selected_targets: [:web, :desktop], tuple_id: nil}},
      {:watcher_state, %{target: nil, source_revision: nil, generation_id: nil},
       %{state: :watching, watched_roots: 2, failure_code: nil}},
      {:build_started, build, %{profile: :dev, stages: [:cargo_web, :bindgen_web]}},
      {:stage_started, build, %{stage: :cargo_web, input_bytes: nil}},
      {:stage_progress, build, %{stage: :cargo_web, completed: 1, total: 2, unit: :messages}},
      {:stage_finished, build,
       %{stage: :cargo_web, result: :ok, duration_ms: 1, input_bytes: 2, output_bytes: 3}},
      {:build_succeeded, generated,
       %{build_key: @digest, artifact_id: @digest, manifest_digest: @digest}},
      {:build_failed, build, %{failure_code: :cargo_failed, diagnostic_count: 1}},
      {:build_cancelled, build, %{reason: :obsolete}},
      {:generation_published, generated, %{artifact_id: @digest, manifest_digest: @digest}},
      {:browser_state, %{target: :web, source_revision: nil, generation_id: nil},
       %{tab_id_hash: @digest, state: :connecting, failure_code: nil}},
      {:desktop_state, %{target: :desktop, source_revision: 1, generation_id: @generation},
       %{state: :ready, pid: 123, readiness: :ipc_v1_verified}},
      {:projection_finished, generated,
       %{transaction_id: @generation, artifact_id: @digest, result: :succeeded}},
      {:cleanup_required, %{target: nil, source_revision: nil, generation_id: nil},
       %{scope: :staging, reason: :cleanup_unconfirmed}},
      {:doctor_finished, none,
       %{overall: :supported, required_findings: 1, unavailable: 0, stale: 0, unknown: 0}},
      {:session_stopping, none, %{reason: :shutdown}}
    ]
  end

  defp event_attributes(:build_started, revision),
    do: event_attributes(:build_started, :web, revision)

  defp event_attributes(:build_failed, revision),
    do: event_attributes(:build_failed, :web, revision)

  defp event_attributes(:build_cancelled, revision),
    do: event_attributes(:build_cancelled, :web, revision)

  defp event_attributes(:stage_progress, revision, completed),
    do: event_attributes(:stage_progress, :web, revision, :cargo_web, completed)

  defp event_attributes(:build_started, target, revision),
    do: %{
      target: target,
      source_revision: revision,
      generation_id: nil,
      type: :build_started,
      payload: %{profile: :dev, stages: [:cargo_web]}
    }

  defp event_attributes(:build_failed, target, revision),
    do: %{
      target: target,
      source_revision: revision,
      generation_id: nil,
      type: :build_failed,
      payload: %{failure_code: :cargo_failed, diagnostic_count: 1}
    }

  defp event_attributes(:build_cancelled, target, revision),
    do: %{
      target: target,
      source_revision: revision,
      generation_id: nil,
      type: :build_cancelled,
      payload: %{reason: :obsolete}
    }

  defp event_attributes(:stage_progress, target, revision, stage, completed),
    do: %{
      target: target,
      source_revision: revision,
      generation_id: nil,
      type: :stage_progress,
      payload: %{stage: stage, completed: completed, total: 10, unit: :messages}
    }
end
