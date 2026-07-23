defmodule Rekindle.InstallVerifyResult do
  @moduledoc "The successful result of verifying an installed Rekindle client."

  alias Rekindle.{Diagnostic, Failure}

  @check_names [
    :compatibility_manifest,
    :source_bundle,
    :client_layout,
    :cargo_graph,
    :phoenix_development,
    :phoenix_production,
    :ignore_rules,
    :generated_targets
  ]
  @checks Enum.map(@check_names, &%{name: &1, status: :verified})
  @fields [
    :status,
    :rekindle_version,
    :application_id,
    :integration,
    :client_root,
    :targets,
    :checks,
    :diagnostics
  ]

  @enforce_keys @fields
  defstruct [contract_version: 1] ++ @fields

  @type check_name ::
          :compatibility_manifest
          | :source_bundle
          | :client_layout
          | :cargo_graph
          | :phoenix_development
          | :phoenix_production
          | :ignore_rules
          | :generated_targets
  @type check :: %{name: check_name(), status: :verified}
  @type integration :: :gpui | :egui | :slint
  @type t :: %__MODULE__{
          contract_version: 1,
          status: :verified,
          rekindle_version: String.t(),
          application_id: String.t(),
          integration: integration(),
          client_root: String.t(),
          targets: [Rekindle.target()],
          checks: [check()],
          diagnostics: [Diagnostic.t()]
        }

  @spec checks() :: [check()]
  def checks, do: @checks

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Failure.t()}
  def new(attributes) do
    attributes = Map.new(attributes)
    version = Map.get(attributes, :contract_version, 1)
    attributes = Map.delete(attributes, :contract_version)

    with true <- version == 1,
         true <- Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
         true <- attributes.status == :verified,
         true <- canonical_semver?(attributes.rekindle_version),
         true <- application_id?(attributes.application_id),
         true <- attributes.integration in [:gpui, :egui, :slint],
         true <- relative_root?(attributes.client_root),
         true <- attributes.targets in [[:web], [:desktop], [:web, :desktop]],
         true <- attributes.checks == @checks,
         {:ok, diagnostics} <- diagnostics(attributes.diagnostics) do
      {:ok, struct!(__MODULE__, %{attributes | diagnostics: diagnostics})}
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = value) do
    %{
      "contract_version" => 1,
      "status" => "verified",
      "rekindle_version" => value.rekindle_version,
      "application_id" => value.application_id,
      "integration" => Atom.to_string(value.integration),
      "client_root" => value.client_root,
      "targets" => Enum.map(value.targets, &Atom.to_string/1),
      "checks" =>
        Enum.map(value.checks, fn check ->
          %{"name" => Atom.to_string(check.name), "status" => "verified"}
        end),
      "diagnostics" => Enum.map(value.diagnostics, &Diagnostic.to_map/1)
    }
  end

  defp canonical_semver?(value) when is_binary(value) and byte_size(value) in 1..128 do
    String.printable?(value) and String.to_charlist(value) |> Enum.all?(&(&1 in 0..127)) and
      case Version.parse(value) do
        {:ok, version} -> Version.to_string(version) == value
        :error -> false
      end
  end

  defp canonical_semver?(_value), do: false

  defp application_id?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and
        Regex.match?(~r/\A[a-z][a-z0-9_-]{0,127}\z/, value)

  defp relative_root?(value) when is_binary(value) do
    segments = Path.split(value)

    byte_size(value) in 1..4_096 and String.valid?(value) and
      String.normalize(value, :nfc) == value and Path.type(value) == :relative and
      not String.contains?(value, ["\\", <<0>>]) and
      Enum.all?(segments, &(&1 not in ["", ".", ".."])) and
      Path.join(segments) == value
  end

  defp relative_root?(_value), do: false

  defp diagnostics(values) when is_list(values) and length(values) <= 256 do
    Enum.reduce_while(values, {:ok, []}, fn
      %Diagnostic{} = value, {:ok, acc} ->
        case Diagnostic.sanitize(value) do
          {:ok, %Diagnostic{target: nil, severity: severity} = diagnostic}
          when severity in [:info, :warning] ->
            {:cont, {:ok, [diagnostic | acc]}}

          _ ->
            {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, diagnostics} -> {:ok, Enum.reverse(diagnostics)}
      _ -> :error
    end
  end

  defp diagnostics(_values), do: :error

  defp invalid do
    {:error,
     Failure.new!(
       target: nil,
       stage: :internal,
       code: :contract_violation,
       message: "Install verification result is invalid"
     )}
  end
end
