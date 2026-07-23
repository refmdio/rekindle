defmodule Rekindle.BuildResult do
  @moduledoc "The successful result of building and sealing one target."

  alias Rekindle.{Diagnostic, Failure, GenerationRef}

  @fields [
    :target,
    :support_level,
    :mode,
    :source_revision,
    :build_key,
    :generation,
    :duration_ms,
    :diagnostics
  ]
  @enforce_keys @fields
  defstruct [contract_version: 1] ++ @fields

  @type t :: %__MODULE__{
          contract_version: 1,
          target: Rekindle.target(),
          support_level: Rekindle.support_level(),
          mode: Rekindle.build_mode(),
          source_revision: non_neg_integer(),
          build_key: String.t(),
          generation: GenerationRef.t(),
          duration_ms: non_neg_integer(),
          diagnostics: [Diagnostic.t()]
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Failure.t()}
  def new(attributes) do
    attributes = Map.new(attributes)
    version = Map.get(attributes, :contract_version, 1)
    attributes = Map.delete(attributes, :contract_version)

    with true <- version == 1,
         true <- Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
         true <- attributes.target in [:web, :desktop],
         true <- Rekindle.SupportLevel.valid?(attributes.support_level),
         true <- attributes.mode in [:dev, :release],
         true <- uint?(attributes.source_revision),
         true <- digest?(attributes.build_key),
         {:ok, %GenerationRef{target: target} = generation} <-
           GenerationRef.new(Map.from_struct(attributes.generation)),
         true <- target == attributes.target,
         true <- generation.support_level == attributes.support_level,
         true <- uint?(attributes.duration_ms),
         {:ok, diagnostics} <- diagnostics(attributes.diagnostics) do
      {:ok, struct!(__MODULE__, %{attributes | generation: generation, diagnostics: diagnostics})}
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
      "target" => Atom.to_string(value.target),
      "support_level" => Atom.to_string(value.support_level),
      "mode" => Atom.to_string(value.mode),
      "source_revision" => value.source_revision,
      "build_key" => value.build_key,
      "generation" => GenerationRef.to_map(value.generation),
      "duration_ms" => value.duration_ms,
      "diagnostics" => Enum.map(value.diagnostics, &Diagnostic.to_map/1)
    }
  end

  defp diagnostics(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn
      %Diagnostic{} = value, {:ok, acc} ->
        case Diagnostic.sanitize(value) do
          {:ok, diagnostic} -> {:cont, {:ok, [diagnostic | acc]}}
          _ -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      _ -> :error
    end
  end

  defp diagnostics(_values), do: :error
  defp uint?(value), do: is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp invalid do
    {:error,
     Failure.new!(
       target: nil,
       stage: :internal,
       code: :contract_violation,
       message: "Build result is invalid"
     )}
  end
end
