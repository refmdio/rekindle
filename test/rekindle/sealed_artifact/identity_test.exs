defmodule Rekindle.SealedArtifact.IdentityTest do
  use ExUnit.Case, async: true

  alias Rekindle.{CanonicalValue, SealedArtifact.Identity}

  @zero String.duplicate("0", 64)

  test "derives the fixed Web identity vector from its exact canonical preimage" do
    member = %{"path" => "app.js", "role" => "javascript", "sha256" => @zero, "size" => 12}
    identity = %{"v" => 2, "build_key" => @zero, "members" => [member]}

    assert CanonicalValue.encode!(identity) ==
             ~s({"build_key":"#{@zero}","members":[{"path":"app.js","role":"javascript","sha256":"#{@zero}","size":12}],"v":2})

    manifest = %{
      "build" => %{"build_key" => @zero},
      "members" => [Map.merge(member, %{"mime" => "ignored", "cache" => "immutable"})]
    }

    assert {:ok, "7a920dcdf1a19ccaf2ae1d10940136565fd0e84fe4f0ae10ad9a2126def7e508"} =
             Identity.derive(:web, manifest)
  end

  test "derives the fixed desktop identity vector from its exact canonical preimage" do
    executable = %{
      "mode" => "executable_owner",
      "path" => "application",
      "sha256" => @zero,
      "size" => 42
    }

    identity = %{"v" => 2, "build_key" => @zero, "executable" => executable}

    assert CanonicalValue.encode!(identity) ==
             ~s({"build_key":"#{@zero}","executable":{"mode":"executable_owner","path":"application","sha256":"#{@zero}","size":42},"v":2})

    manifest = %{"build" => %{"build_key" => @zero}, "executable" => executable}

    assert {:ok, "a247ced27878baf0ece37be2c7a6734a285219ce8bfa278f4deceb0610707a0a"} =
             Identity.derive(:desktop, manifest)
  end

  test "identity excludes publication and presentation metadata but binds every identity field" do
    web = %{
      "build" => %{"build_key" => @zero},
      "members" => [
        %{
          "path" => "app.js",
          "role" => "javascript",
          "sha256" => @zero,
          "size" => 12,
          "mime" => "first",
          "cache" => "immutable"
        }
      ],
      "source_revision" => 1,
      "generation_id" => String.duplicate("1", 32)
    }

    assert {:ok, web_id} = Identity.derive(:web, web)

    assert {:ok, ^web_id} =
             Identity.derive(:web, %{
               web
               | "source_revision" => 999,
                 "generation_id" => String.duplicate("2", 32),
                 "members" => [
                   web["members"]
                   |> hd()
                   |> Map.merge(%{"mime" => "second", "cache" => "no_cache"})
                 ]
             })

    for mutation <- [
          &put_in(&1, ["build", "build_key"], String.duplicate("1", 64)),
          &put_in(&1, ["members", Access.at(0), "path"], "other.js"),
          &put_in(&1, ["members", Access.at(0), "role"], "asset"),
          &put_in(&1, ["members", Access.at(0), "sha256"], String.duplicate("2", 64)),
          &put_in(&1, ["members", Access.at(0), "size"], 13)
        ] do
      assert {:ok, changed} = Identity.derive(:web, mutation.(web))
      refute changed == web_id
    end

    desktop = %{
      "build" => %{"build_key" => @zero},
      "executable" => %{
        "path" => "application",
        "sha256" => @zero,
        "size" => 42,
        "mode" => "executable_owner"
      }
    }

    assert {:ok, desktop_id} = Identity.derive(:desktop, desktop)

    for mutation <- [
          &put_in(&1, ["build", "build_key"], String.duplicate("1", 64)),
          &put_in(&1, ["executable", "path"], "other"),
          &put_in(&1, ["executable", "sha256"], String.duplicate("2", 64)),
          &put_in(&1, ["executable", "size"], 43),
          &put_in(&1, ["executable", "mode"], "regular")
        ] do
      assert {:ok, changed} = Identity.derive(:desktop, mutation.(desktop))
      refute changed == desktop_id
    end
  end
end
