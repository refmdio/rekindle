defmodule Rekindle.SealedArtifact.WebMemberMetadataTest do
  use ExUnit.Case, async: true

  alias Rekindle.SealedArtifact.WebMemberMetadata

  test "resolves every closed role and asset MIME assignment" do
    expected = [
      {"bootstrap", "entry.js", "text/javascript; charset=utf-8", "no_cache"},
      {"javascript", "app.js", "text/javascript; charset=utf-8", "immutable"},
      {"wasm", "app.wasm", "application/wasm", "immutable"},
      {"css", "styles/app.css", "text/css; charset=utf-8", "immutable"},
      {"source_map", "app.js.map", "application/json; charset=utf-8", "immutable"},
      {"asset", "assets/a.png", "image/png", "immutable"},
      {"asset", "assets/a.jpg", "image/jpeg", "immutable"},
      {"asset", "assets/a.jpeg", "image/jpeg", "immutable"},
      {"asset", "assets/a.gif", "image/gif", "immutable"},
      {"asset", "assets/a.webp", "image/webp", "immutable"},
      {"asset", "assets/a.avif", "image/avif", "immutable"},
      {"asset", "assets/a.svg", "image/svg+xml", "immutable"},
      {"asset", "assets/a.ico", "image/x-icon", "immutable"},
      {"asset", "assets/a.woff", "font/woff", "immutable"},
      {"asset", "assets/a.woff2", "font/woff2", "immutable"},
      {"asset", "assets/a.ttf", "font/ttf", "immutable"},
      {"asset", "assets/a.otf", "font/otf", "immutable"},
      {"asset", "assets/a.txt", "text/plain; charset=utf-8", "immutable"},
      {"asset", "assets/a.json", "application/json; charset=utf-8", "immutable"},
      {"asset", "assets/a.bin", "application/octet-stream", "immutable"},
      {"asset", "assets/README", "application/octet-stream", "immutable"},
      {"asset", "assets/case.PNG", "image/png", "immutable"}
    ]

    for {role, path, mime, cache} <- expected do
      assert {:ok, ^mime, ^cache} = WebMemberMetadata.resolve(role, path)
    end
  end

  test "rejects reserved extensions and wrong role-extension combinations" do
    invalid = [
      {"bootstrap", "entry.css"},
      {"javascript", "app.wasm"},
      {"wasm", "app.js"},
      {"css", "app.js"},
      {"source_map", "app.js"},
      {"asset", "app.js"},
      {"asset", "app.wasm"},
      {"asset", "app.css"},
      {"asset", "app.map"},
      {"unknown", "asset.bin"},
      {"JavaScript", "app.js"},
      {nil, "app.js"},
      {"javascript", nil}
    ]

    for {role, path} <- invalid do
      assert {:error, :role_extension} = WebMemberMetadata.resolve(role, path)
    end
  end
end
