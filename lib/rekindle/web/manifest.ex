defmodule Rekindle.Web.Manifest do
  @moduledoc false

  alias Rekindle.Web.Error

  @version 1
  @generation ~r/\A[0-9a-f]{32}\z/

  @doc false
  @spec read(Path.t()) :: {:ok, map()} | {:error, Error.t()}
  def read(root) do
    path = Path.join(root, "manifest.json")

    with {:ok, contents} <- File.read(path),
         {:ok, manifest} <- Jason.decode(contents) do
      {:ok, manifest}
    else
      {:error, %Jason.DecodeError{} = error} ->
        error(:invalid_manifest, "Web manifest is invalid: #{Exception.message(error)}")

      {:error, reason} ->
        file_error(:manifest_read, path, reason)
    end
  end

  @spec create(Path.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def create(root, entry) do
    manifest = %{"version" => @version, "generation" => generation(), "entry" => entry}

    case validate(root, manifest) do
      :ok -> {:ok, manifest}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec validate(Path.t(), map()) :: :ok | {:error, Error.t()}
  def validate(
        root,
        %{"version" => @version, "generation" => generation, "entry" => entry} = manifest
      )
      when map_size(manifest) == 3 and is_binary(generation) and is_binary(entry) do
    with true <- Regex.match?(@generation, generation),
         :ok <- relative_path(entry),
         true <- File.regular?(Path.join(root, entry)) do
      :ok
    else
      false -> error(:missing_entry, "Web entry is missing or the manifest is invalid")
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def validate(_root, _manifest),
    do: error(:invalid_manifest, "Web manifest has an unsupported shape")

  @doc false
  @spec read_member(Path.t(), map(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def read_member(root, manifest, requested) when is_binary(requested) do
    with :ok <- validate(root, manifest),
         :ok <- relative_path(requested),
         {:ok, contents} <- File.read(Path.join(root, requested)) do
      {:ok, contents}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, :enoent} ->
        error(:missing_member, "Web generation member is missing: #{requested}")

      {:error, reason} ->
        file_error(:member_read, requested, reason)
    end
  end

  defp relative_path(path) when is_binary(path) and path != "" do
    root = "/generation"
    expanded = Path.expand(path, root)

    if Path.type(path) == :relative and expanded != root and
         String.starts_with?(expanded, root <> "/") and
         Path.relative_to(expanded, root) == path do
      :ok
    else
      error(:invalid_path, "Web member path must remain relative: #{inspect(path)}")
    end
  end

  defp relative_path(path),
    do: error(:invalid_path, "Web member path must be a non-empty string: #{inspect(path)}")

  defp generation do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp file_error(kind, path, reason),
    do: error(kind, "cannot read #{path}: #{:file.format_error(reason)}")

  defp error(kind, message), do: {:error, Error.new(kind, message)}
end
