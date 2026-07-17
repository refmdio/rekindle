defmodule Rekindle.Event do
  @moduledoc "A closed, ordered project runtime event."

  alias Rekindle.{BuildGraph, Failure}

  @fields [
    :project_session,
    :sequence,
    :target,
    :source_revision,
    :generation_id,
    :type,
    :payload
  ]
  @enforce_keys @fields
  defstruct [contract_version: 1] ++ @fields

  @types ~w[configuration_rejected session_ready watcher_state build_started stage_started stage_progress stage_finished build_succeeded build_failed build_cancelled generation_published browser_state desktop_state projection_finished cleanup_required doctor_finished session_stopping]a
  @terminal ~w[build_succeeded build_failed build_cancelled]a

  @type t :: %__MODULE__{}

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Failure.t()}
  def new(attributes) do
    attributes = Map.new(attributes)
    version = Map.get(attributes, :contract_version, 1)
    attributes = Map.delete(attributes, :contract_version)

    with true <- version == 1,
         true <- Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
         true <- id?(attributes.project_session),
         true <- uint?(attributes.sequence),
         true <- attributes.type in @types,
         :ok <- roots(attributes),
         :ok <- payload(attributes.type, attributes.payload) do
      {:ok, struct!(__MODULE__, attributes)}
    else
      _ -> invalid("Event does not match the v1 contract")
    end
  rescue
    _ -> invalid("Event does not match the v1 contract")
  end

  @spec terminal?(t() | atom()) :: boolean()
  def terminal?(%__MODULE__{type: type}), do: type in @terminal
  def terminal?(type) when is_atom(type), do: type in @terminal

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    %{
      "contract_version" => 1,
      "project_session" => event.project_session,
      "sequence" => event.sequence,
      "target" => encode(event.target),
      "source_revision" => event.source_revision,
      "generation_id" => event.generation_id,
      "type" => Atom.to_string(event.type),
      "payload" => encode(event.payload)
    }
  end

  defp roots(%{type: type, target: nil, source_revision: nil, generation_id: nil})
       when type in [:configuration_rejected, :session_ready, :doctor_finished, :session_stopping],
       do: :ok

  defp roots(%{type: :watcher_state, target: nil, source_revision: revision, generation_id: nil}),
    do: if(is_nil(revision) or uint?(revision), do: :ok, else: :error)

  defp roots(%{type: type, target: target, source_revision: revision, generation_id: nil})
       when type in [
              :build_started,
              :stage_started,
              :stage_progress,
              :stage_finished,
              :build_failed,
              :build_cancelled
            ] and
              target in [:web, :desktop],
       do: if(uint?(revision), do: :ok, else: :error)

  defp roots(%{type: type, target: target, source_revision: revision, generation_id: generation})
       when type in [:build_succeeded, :generation_published, :projection_finished] and
              target in [:web, :desktop],
       do: if(uint?(revision) and id?(generation), do: :ok, else: :error)

  defp roots(%{
         type: :browser_state,
         target: :web,
         source_revision: revision,
         generation_id: generation
       }),
       do: if(optional_uint?(revision) and optional_id?(generation), do: :ok, else: :error)

  defp roots(%{
         type: :desktop_state,
         target: :desktop,
         source_revision: revision,
         generation_id: generation
       }),
       do: if(optional_uint?(revision) and optional_id?(generation), do: :ok, else: :error)

  defp roots(%{
         type: :cleanup_required,
         target: target,
         source_revision: nil,
         generation_id: nil
       }),
       do: if(target in [nil, :web, :desktop], do: :ok, else: :error)

  defp roots(_attributes), do: :error

  defp payload(:configuration_rejected, value),
    do:
      fields(value, [:failure_code, :diagnostic_count], fn ->
        config_code?(value.failure_code) and uint?(value.diagnostic_count)
      end)

  defp payload(:session_ready, value),
    do:
      fields(value, [:selected_targets, :tuple_id], fn ->
        value.selected_targets in [[:web], [:desktop], [:web, :desktop]] and
          optional_text?(value.tuple_id)
      end)

  defp payload(:watcher_state, value),
    do:
      fields(value, [:state, :watched_roots, :failure_code], fn ->
        value.state in [:starting, :watching, :overflow, :stopped] and uint?(value.watched_roots) and
          optional_failure_code?(value.failure_code)
      end)

  defp payload(:build_started, value),
    do:
      fields(value, [:profile, :stages], fn ->
        value.profile in [:dev, :release] and graph_nodes?(value.stages)
      end)

  defp payload(:stage_started, value),
    do:
      fields(value, [:stage, :input_bytes], fn ->
        graph_node?(value.stage) and optional_uint?(value.input_bytes)
      end)

  defp payload(:stage_progress, value),
    do:
      fields(value, [:stage, :completed, :total, :unit], fn ->
        graph_node?(value.stage) and uint?(value.completed) and optional_uint?(value.total) and
          (is_nil(value.total) or value.completed <= value.total) and
          value.unit in [:bytes, :files, :messages]
      end)

  defp payload(:stage_finished, value),
    do:
      fields(value, [:stage, :result, :duration_ms, :input_bytes, :output_bytes], fn ->
        graph_node?(value.stage) and value.result in [:ok, :error, :cancelled] and
          Enum.all?([value.duration_ms, value.input_bytes, value.output_bytes], &uint?/1)
      end)

  defp payload(:build_succeeded, value),
    do:
      fields(value, [:build_key, :artifact_id, :manifest_digest], fn ->
        Enum.all?([value.build_key, value.artifact_id, value.manifest_digest], &digest?/1)
      end)

  defp payload(:build_failed, value),
    do:
      fields(value, [:failure_code, :diagnostic_count], fn ->
        failure_code?(value.failure_code) and uint?(value.diagnostic_count)
      end)

  defp payload(:build_cancelled, value),
    do:
      fields(value, [:reason], fn -> value.reason in [:obsolete, :timeout, :shutdown, :caller] end)

  defp payload(:generation_published, value),
    do:
      fields(value, [:artifact_id, :manifest_digest], fn ->
        digest?(value.artifact_id) and digest?(value.manifest_digest)
      end)

  defp payload(:browser_state, value),
    do:
      fields(value, [:tab_id_hash, :state, :failure_code], fn ->
        digest?(value.tab_id_hash) and
          value.state in [
            :connecting,
            :joined,
            :snapshotting,
            :reloading,
            :starting,
            :applied,
            :failed
          ] and optional_failure_code?(value.failure_code)
      end)

  defp payload(:desktop_state, value),
    do:
      fields(value, [:state, :pid, :readiness], fn ->
        value.state in [
          :spawning,
          :authenticating,
          :restoring,
          :ready,
          :stopping,
          :exited,
          :failed
        ] and optional_uint?(value.pid) and
          value.readiness in [:ipc_v1_verified, :startup_grace_unverified]
      end)

  defp payload(:projection_finished, value),
    do:
      fields(value, [:transaction_id, :artifact_id, :result], fn ->
        id?(value.transaction_id) and digest?(value.artifact_id) and
          value.result in [:succeeded, :failed]
      end)

  defp payload(:cleanup_required, value),
    do:
      fields(value, [:scope, :reason], fn ->
        value.scope in [:process, :staging, :generation, :projection] and
          failure_code?(value.reason)
      end)

  defp payload(:doctor_finished, value),
    do:
      fields(value, [:overall, :required_findings, :unavailable, :stale, :unknown], fn ->
        value.overall in [:supported, :unavailable, :stale, :unknown] and
          Enum.all?(
            [value.required_findings, value.unavailable, value.stale, value.unknown],
            &uint?/1
          )
      end)

  defp payload(:session_stopping, value),
    do:
      fields(value, [:reason], fn ->
        value.reason in [:shutdown, :supervisor, :configuration_changed]
      end)

  defp fields(value, expected, validator) when is_map(value) do
    if Map.keys(value) |> Enum.sort() == Enum.sort(expected) and validator.(),
      do: :ok,
      else: :error
  rescue
    _ -> :error
  end

  defp fields(_value, _expected, _validator), do: :error
  defp graph_node?(value), do: value in BuildGraph.nodes()

  defp graph_nodes?(values) when is_list(values) do
    orders = Enum.map(values, fn node -> BuildGraph.order(node) end)

    values == Enum.uniq(values) and Enum.all?(values, &graph_node?/1) and
      orders == Enum.sort(orders)
  end

  defp graph_nodes?(_values), do: false

  defp config_code?(value),
    do:
      value in ~w[config_missing config_invalid target_undeclared path_invalid path_overlap install_conflict]a

  defp failure_code?(value), do: value in Failure.codes()
  defp optional_failure_code?(nil), do: true
  defp optional_failure_code?(value), do: failure_code?(value)
  defp uint?(value), do: is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991
  defp optional_uint?(nil), do: true
  defp optional_uint?(value), do: uint?(value)
  defp id?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{32}\z/, value)
  defp optional_id?(nil), do: true
  defp optional_id?(value), do: id?(value)
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp optional_text?(nil), do: true

  defp optional_text?(value),
    do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)

  defp encode(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp encode(value) when is_list(value), do: Enum.map(value, &encode/1)

  defp encode(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {encode(key), encode(item)} end)

  defp encode(value), do: value

  defp invalid(message) do
    {:error,
     Failure.new!(target: nil, stage: :internal, code: :contract_violation, message: message)}
  end
end
