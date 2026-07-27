defmodule Rekindle.Desktop.Manifest do
  @moduledoc false

  alias Rekindle.Desktop.Error

  @version 1
  @integrations ["gpui", "egui", "slint"]

  @doc false
  @spec read(Path.t()) :: {:ok, map()} | {:error, Error.t()}
  def read(root) do
    path = Path.join(root, "manifest.json")

    with {:ok, contents} <- File.read(path),
         {:ok, manifest} <- Jason.decode(contents) do
      {:ok, manifest}
    else
      {:error, %Jason.DecodeError{} = error} ->
        error(:invalid_manifest, "desktop manifest is invalid: #{Exception.message(error)}")

      {:error, reason} ->
        file_error(:manifest_read, path, reason)
    end
  end

  @spec create(Path.t(), String.t(), String.t(), String.t(), String.t(), atom() | String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(root, executable, target, package, binary, integration) do
    manifest = %{
      "version" => @version,
      "target" => target,
      "package" => package,
      "binary" => binary,
      "integration" => to_string(integration),
      "executable" => executable
    }

    case validate(root, manifest) do
      :ok -> {:ok, manifest}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec validate(Path.t(), map()) :: :ok | {:error, Error.t()}
  def validate(
        root,
        %{
          "version" => @version,
          "target" => target,
          "package" => package,
          "binary" => binary,
          "integration" => integration,
          "executable" => executable
        } = manifest
      )
      when map_size(manifest) == 6 and is_binary(target) and target != "" and
             is_binary(package) and package != "" and is_binary(binary) and binary != "" and
             integration in @integrations do
    with :ok <- component(target, "target"),
         :ok <- component(executable, "executable"),
         {:ok, %{type: :regular, mode: mode}} <- File.stat(Path.join(root, executable)),
         true <- Bitwise.band(mode, 0o111) != 0 do
      :ok
    else
      false -> error(:not_executable, "desktop artifact is not executable")
      {:ok, _stat} -> error(:invalid_executable, "desktop artifact is not a regular file")
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> file_error(:executable_read, Path.join(root, executable), reason)
    end
  end

  def validate(_root, _manifest),
    do: error(:invalid_manifest, "desktop manifest has an unsupported shape")

  defp component(value, label) when is_binary(value) and value != "" do
    if Path.basename(value) == value and value not in [".", ".."],
      do: :ok,
      else: error(:invalid_manifest, "desktop #{label} must be a single path component")
  end

  defp component(_value, label),
    do: error(:invalid_manifest, "desktop #{label} must be a single path component")

  defp file_error(kind, path, reason),
    do: error(kind, "cannot read #{path}: #{:file.format_error(reason)}")

  defp error(kind, message), do: {:error, Error.new(kind, message)}
end
