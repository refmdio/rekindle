defmodule Rekindle.Desktop.Manifest do
  @moduledoc false

  alias Rekindle.Desktop.Error

  @version 1

  @spec create(Path.t(), String.t(), String.t(), String.t(), String.t(), atom() | String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(root, executable, target, package, binary, integration) do
    with :ok <- component(executable, "executable"),
         :ok <- component(target, "target"),
         {:ok, integration} <- integration(integration),
         {:ok, contents} <- read_executable(root, executable) do
      fields = %{
        "target" => target,
        "package" => package,
        "binary" => binary,
        "integration" => integration,
        "executable" => executable,
        "sha256" => sha256(contents)
      }

      {:ok, Map.merge(fields, %{"version" => @version, "generation" => identity(fields)})}
    end
  end

  @spec validate(Path.t(), map()) :: :ok | {:error, Error.t()}
  def validate(root, %{
        "version" => @version,
        "generation" => generation,
        "target" => target,
        "package" => package,
        "binary" => binary,
        "integration" => integration,
        "executable" => executable,
        "sha256" => expected
      })
      when is_binary(generation) and is_binary(target) and target != "" and is_binary(package) and
             package != "" and is_binary(binary) and binary != "" and
             integration in ["gpui", "egui", "slint"] and is_binary(expected) do
    fields = %{
      "target" => target,
      "package" => package,
      "binary" => binary,
      "integration" => integration,
      "executable" => executable,
      "sha256" => expected
    }

    with :ok <- component(executable, "executable"),
         :ok <- component(target, "target"),
         {:ok, contents} <- read_executable(root, executable),
         :ok <- checksum(contents, expected),
         :ok <- generation_identity(fields, generation) do
      :ok
    end
  end

  def validate(_root, _manifest),
    do: error(:invalid_manifest, "desktop manifest has an unsupported shape")

  defp read_executable(root, executable) do
    path = Path.join(root, executable)

    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o111) != 0 do
          case File.read(path) do
            {:ok, contents} -> {:ok, contents}
            {:error, reason} -> file_error(:executable_read, path, reason)
          end
        else
          error(:not_executable, "desktop artifact is not executable: #{path}")
        end

      {:ok, _stat} ->
        error(:invalid_executable, "desktop artifact is not a regular file: #{path}")

      {:error, reason} ->
        file_error(:executable_read, path, reason)
    end
  end

  defp component(value, label) when is_binary(value) and value != "" do
    if Path.basename(value) == value and value not in [".", ".."],
      do: :ok,
      else: error(:invalid_manifest, "desktop #{label} must be a single path component")
  end

  defp component(_value, label),
    do: error(:invalid_manifest, "desktop #{label} must be a single path component")

  defp integration(value) when value in [:gpui, :egui, :slint],
    do: {:ok, Atom.to_string(value)}

  defp integration(value) when value in ["gpui", "egui", "slint"], do: {:ok, value}
  defp integration(_value), do: error(:invalid_manifest, "desktop integration is invalid")

  defp identity(fields), do: fields |> Jason.encode!() |> sha256()

  defp checksum(contents, expected) do
    if sha256(contents) == expected,
      do: :ok,
      else: error(:executable_hash, "desktop executable hash does not match its manifest")
  end

  defp generation_identity(fields, generation) do
    if identity(fields) == generation,
      do: :ok,
      else: error(:invalid_manifest, "desktop manifest generation does not match its fields")
  end

  defp sha256(contents),
    do: contents |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp file_error(kind, path, reason),
    do: error(kind, "cannot read #{path}: #{:file.format_error(reason)}")

  defp error(kind, message), do: {:error, Error.new(kind, message)}
end
