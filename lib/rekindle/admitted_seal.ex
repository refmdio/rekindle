defmodule Rekindle.AdmittedSeal do
  @moduledoc false

  alias Rekindle.ArtifactStore
  alias Rekindle.ArtifactStore.Lease
  alias Rekindle.SealedArtifact.{Desktop, Validation, Web}
  alias Rekindle.{Failure, GenerationRef}

  @fields [
    :target,
    :source_revision,
    :generation_id,
    :artifact_id,
    :manifest_digest,
    :producer,
    :lease,
    :seal_result,
    :sealed,
    :fingerprint
  ]
  @enforce_keys @fields
  defstruct @fields

  @type sealed :: {:web, Web.t()} | {:desktop, Desktop.t()}
  @type t :: %__MODULE__{}

  @spec admit(GenServer.server(), Web.t() | Desktop.t()) ::
          {:ok, t()} | {:error, Failure.t()}
  def admit(store, sealed) do
    with {:ok, target, generation, source_revision, producer, union} <- summarize(sealed),
         {:ok, lease} <- ArtifactStore.acquire(store, generation, source_revision),
         :ok <- exact_lease(lease, generation) do
      common = common(target, generation, source_revision, producer, :sealed, union)

      {:ok,
       struct!(
         __MODULE__,
         Map.merge(common, %{
           lease: lease,
           fingerprint: Validation.fingerprint(common, lease.token)
         })
       )}
    end
  end

  @spec fetch(t()) :: {:ok, map()} | {:error, Failure.t()}
  def fetch(%__MODULE__{} = admitted) do
    with {:ok, target, generation, source_revision, producer, union} <-
           summarize_union(admitted.sealed),
         true <- exact_fields?(admitted),
         true <- identity_matches?(admitted, target, generation, source_revision, producer, union),
         :ok <- exact_lease(admitted.lease, generation),
         true <- ArtifactStore.valid_lease?(admitted.lease),
         common <- common(target, generation, source_revision, producer, :sealed, union),
         true <- admitted.fingerprint == Validation.fingerprint(common, admitted.lease.token) do
      {:ok, Map.put(common, :lease, admitted.lease)}
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  catch
    _, _ -> invalid()
  end

  def fetch(_admitted), do: invalid()

  defp summarize(%Web{} = sealed), do: summarize_union({:web, sealed})
  defp summarize(%Desktop{} = sealed), do: summarize_union({:desktop, sealed})
  defp summarize(_sealed), do: invalid()

  defp summarize_union({:web, %Web{} = sealed}) do
    case Web.new(
           Map.take(Map.from_struct(sealed), ~w[generation source_revision manifest seal_result]a)
         ) do
      {:ok, ^sealed} ->
        {:ok, :web, sealed.generation, sealed.source_revision, sealed.producer, {:web, sealed}}

      {:ok, _verified} ->
        invalid()

      {:error, _} = error ->
        error
    end
  end

  defp summarize_union({:desktop, %Desktop{} = sealed}) do
    case Desktop.new(
           Map.take(Map.from_struct(sealed), ~w[generation source_revision manifest seal_result]a)
         ) do
      {:ok, ^sealed} ->
        {:ok, :desktop, sealed.generation, sealed.source_revision, sealed.producer,
         {:desktop, sealed}}

      {:ok, _verified} ->
        invalid()

      {:error, _} = error ->
        error
    end
  end

  defp summarize_union(_union), do: invalid()

  defp common(target, generation, source_revision, producer, seal_result, union) do
    %{
      target: target,
      source_revision: source_revision,
      generation_id: generation.generation_id,
      artifact_id: generation.artifact_id,
      manifest_digest: generation.manifest_digest,
      producer: producer,
      seal_result: seal_result,
      sealed: union
    }
  end

  defp exact_lease(%Lease{} = lease, %GenerationRef{} = generation) do
    if lease.target == generation.target and lease.generation_id == generation.generation_id and
         lease.artifact_id == generation.artifact_id,
       do: :ok,
       else: invalid()
  end

  defp exact_lease(_lease, _generation), do: invalid()

  defp exact_fields?(admitted),
    do: Map.from_struct(admitted) |> Map.keys() |> Enum.sort() == Enum.sort(@fields)

  defp identity_matches?(admitted, target, generation, source_revision, producer, union) do
    admitted.target == target and admitted.source_revision == source_revision and
      admitted.generation_id == generation.generation_id and
      admitted.artifact_id == generation.artifact_id and
      admitted.manifest_digest == generation.manifest_digest and admitted.producer == producer and
      admitted.seal_result == :sealed and admitted.sealed == union
  end

  defp invalid do
    {:error,
     Failure.new!(
       target: nil,
       stage: :artifact,
       code: :manifest_invalid,
       message: "Admitted sealed artifact is invalid"
     )}
  end
end
