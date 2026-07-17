defmodule Rekindle.SealedArtifact.WebMemberMetadata do
  @moduledoc false

  @asset_mime_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".avif" => "image/avif",
    ".svg" => "image/svg+xml",
    ".ico" => "image/x-icon",
    ".woff" => "font/woff",
    ".woff2" => "font/woff2",
    ".ttf" => "font/ttf",
    ".otf" => "font/otf",
    ".txt" => "text/plain; charset=utf-8",
    ".json" => "application/json; charset=utf-8"
  }

  @spec resolve(String.t(), String.t()) ::
          {:ok, String.t(), String.t()} | {:error, :role_extension}
  def resolve(role, path) when is_binary(path) do
    extension = path |> case_fold() |> Path.extname()

    case {role, extension} do
      {"bootstrap", ".js"} ->
        {:ok, "text/javascript; charset=utf-8", "no_cache"}

      {"javascript", ".js"} ->
        {:ok, "text/javascript; charset=utf-8", "immutable"}

      {"wasm", ".wasm"} ->
        {:ok, "application/wasm", "immutable"}

      {"css", ".css"} ->
        {:ok, "text/css; charset=utf-8", "immutable"}

      {"source_map", ".map"} ->
        {:ok, "application/json; charset=utf-8", "immutable"}

      {"asset", extension} when extension not in [".js", ".wasm", ".css", ".map"] ->
        {:ok, Map.get(@asset_mime_types, extension, "application/octet-stream"), "immutable"}

      _ ->
        {:error, :role_extension}
    end
  end

  def resolve(_role, _path), do: {:error, :role_extension}

  defp case_fold(value),
    do: value |> String.to_charlist() |> :string.casefold() |> List.to_string()
end
