defmodule Rekindle.Cargo.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Rekindle.Cargo.{Arguments, Discovery, Metadata}
  alias Rekindle.Config.{DesktopTarget, WebTarget}

  test "constructs exact locked metadata and build argv from normalized Web configuration" do
    root = Path.join(System.tmp_dir!(), "rekindle-cargo-arguments")

    config = %WebTarget{
      package: "sample-ui",
      binary: "sample-web",
      backend: :canonical,
      features: ["zeta", "alpha"],
      default_features: false,
      profiles: %{dev: "dev-fast", release: "release-small"},
      public: nil,
      hot_styles: [],
      projection: %{mode: :phoenix_static, root: "priv/static/rekindle"},
      toolchain: nil,
      rust_target: "wasm32-unknown-unknown",
      environment: nil
    }

    assert {:ok, metadata} =
             Arguments.metadata(root, :web, config, :dev, "wasm32-unknown-unknown")

    assert metadata.operation == :metadata
    assert metadata.cwd == root
    assert metadata.manifest_path == Path.join(root, "Cargo.toml")

    assert metadata.argv == [
             "metadata",
             "--format-version",
             "1",
             "--locked",
             "--filter-platform",
             "wasm32-unknown-unknown",
             "--manifest-path",
             Path.join(root, "Cargo.toml"),
             "--no-default-features",
             "--features",
             "alpha,zeta"
           ]

    assert metadata.selection == %{
             target: :web,
             package: "sample-ui",
             binary: "sample-web",
             rust_target: "wasm32-unknown-unknown",
             profile: "dev-fast",
             features: ["alpha", "zeta"],
             default_features: false
           }

    assert {:ok, build} =
             Arguments.build(root, :web, config, :release, "wasm32-unknown-unknown")

    assert build.argv == [
             "build",
             "--message-format=json-render-diagnostics",
             "--locked",
             "--manifest-path",
             Path.join(root, "Cargo.toml"),
             "--package",
             "sample-ui",
             "--bin",
             "sample-web",
             "--profile",
             "release-small",
             "--target",
             "wasm32-unknown-unknown",
             "--no-default-features",
             "--features",
             "alpha,zeta"
           ]
  end

  test "constructs desktop argv without optional feature flags and rejects mismatched inputs" do
    root = Path.join(System.tmp_dir!(), "rekindle-cargo-desktop")
    config = desktop_target()

    assert {:ok, request} =
             Arguments.metadata(root, :desktop, config, :dev, "x86_64-unknown-linux-gnu")

    refute "--features" in request.argv
    refute "--no-default-features" in request.argv
    assert request.selection.profile == "dev"

    web = struct(WebTarget, Map.from_struct(config) |> Map.drop([:runtime]))

    assert {:error, %{code: :cargo_metadata_failed}} =
             Arguments.metadata(root, :desktop, web, :dev, "x86_64-unknown-linux-gnu")

    assert {:error, %{code: :cargo_metadata_failed}} =
             Arguments.metadata("relative", :desktop, config, :dev, "x86_64-unknown-linux-gnu")

    assert {:error, %{code: :cargo_metadata_failed}} =
             Arguments.metadata(root, :desktop, config, :dev, "bad\ntriple")
  end

  test "decodes a single-package workspace and selects the exact binary" do
    map = metadata_map()

    assert {:ok, metadata} = Metadata.decode(Jason.encode!(map), :web)
    assert {:ok, inventory} = Discovery.select(metadata, selection())

    assert inventory.workspace_root == "/workspace/client"
    assert inventory.target_directory == "/workspace/client/target"
    assert inventory.selected_package.id == "path+file:///workspace/client#sample-ui@0.1.0"
    assert inventory.selected_target.name == "sample-web"
    assert Enum.map(inventory.dependency_packages, & &1.name) == ["sample-ui", "shared-ui"]
    assert Enum.map(inventory.local_packages, & &1.name) == ["sample-ui", "shared-ui"]
    assert inventory.has_local_build_script?
  end

  test "uses package ids for renamed path dependencies in a virtual workspace" do
    map =
      metadata_map()
      |> Map.put("workspace_root", "/workspace")
      |> Map.put("target_directory", "/workspace/target")
      |> update_in(["resolve", "nodes"], fn [root, dependency] ->
        [
          Map.put(root, "deps", [
            %{
              "name" => "renamed_shared",
              "pkg" => dependency["id"],
              "dep_kinds" => [%{"kind" => nil, "target" => nil}]
            },
            %{
              "name" => "renamed_shared_build",
              "pkg" => dependency["id"],
              "dep_kinds" => [%{"kind" => "build", "target" => nil}]
            }
          ]),
          dependency
        ]
      end)

    assert {:ok, metadata} = Metadata.decode(Jason.encode!(map), :web)
    assert {:ok, inventory} = Discovery.select(metadata, selection())
    assert Enum.map(inventory.dependency_packages, & &1.name) == ["sample-ui", "shared-ui"]
  end

  test "does not select path or registry dependencies as application packages" do
    for source <- [nil, "registry+https://github.com/rust-lang/crates.io-index"] do
      map = metadata_map()
      dependency_id = map["resolve"]["nodes"] |> Enum.at(1) |> Map.fetch!("id")

      map =
        update_in(map, ["packages", Access.at(1)], fn package ->
          package
          |> Map.put("name", "dependency-app")
          |> Map.put("source", source)
          |> Map.put("targets", [
            %{
              "name" => "dependency-bin",
              "kind" => ["bin"],
              "crate_types" => ["bin"],
              "src_path" => "/workspace/shared/src/main.rs"
            }
          ])
        end)

      assert dependency_id not in map["workspace_members"]
      assert {:ok, metadata} = Metadata.decode(Jason.encode!(map), :web)

      assert {:error, %{code: :package_not_found}} =
               Discovery.select(metadata, %{
                 selection()
                 | package: "dependency-app",
                   binary: "dependency-bin",
                   features: []
               })
    end
  end

  test "selects an exact member in virtual and multi-package workspaces" do
    map = metadata_map()
    dependency_id = map["resolve"]["nodes"] |> Enum.at(1) |> Map.fetch!("id")

    map =
      map
      |> Map.put("workspace_root", "/workspace")
      |> Map.put("target_directory", "/workspace/target")
      |> Map.update!("workspace_members", &Enum.sort([dependency_id | &1]))
      |> update_in(["packages", Access.at(1)], fn package ->
        package
        |> Map.put("features", %{"desktop" => []})
        |> Map.put("targets", [
          %{
            "name" => "shared-bin",
            "kind" => ["bin"],
            "crate_types" => ["bin"],
            "src_path" => "/workspace/shared/src/main.rs"
          }
        ])
      end)

    assert {:ok, metadata} = Metadata.decode(Jason.encode!(map), :desktop)

    assert {:ok, inventory} =
             Discovery.select(metadata, %{
               selection()
               | target: :desktop,
                 package: "shared-ui",
                 binary: "shared-bin",
                 rust_target: "x86_64-unknown-linux-gnu",
                 features: ["desktop"]
             })

    assert inventory.selected_package.id == dependency_id
    assert inventory.selected_target.name == "shared-bin"
  end

  test "ignores matching dependency names when selecting a workspace member" do
    map = put_in(metadata_map(), ["packages", Access.at(1), "name"], "sample-ui")
    assert {:ok, metadata} = Metadata.decode(Jason.encode!(map), :web)
    assert {:ok, inventory} = Discovery.select(metadata, selection())
    assert inventory.selected_package.id == hd(metadata.workspace_members)
  end

  test "fails closed for missing or ambiguous packages and binary targets" do
    assert {:ok, metadata} = Metadata.decode(Jason.encode!(metadata_map()), :web)

    assert {:error, %{code: :package_not_found}} =
             Discovery.select(metadata, %{selection() | package: "missing"})

    duplicate = %{hd(metadata.packages) | id: "duplicate", manifest_path: "/other/Cargo.toml"}

    ambiguous_package = %{
      metadata
      | packages: [duplicate | metadata.packages],
        workspace_members: [duplicate.id | metadata.workspace_members]
    }

    assert {:error, %{code: :cargo_metadata_failed}} =
             Discovery.select(ambiguous_package, selection())

    assert {:error, %{code: :target_not_found}} =
             Discovery.select(metadata, %{selection() | binary: "missing"})

    [selected | rest] = metadata.packages
    [target | targets] = selected.targets
    ambiguous_target = %{target | src_path: "/workspace/client/src/bin/other.rs"}
    selected = %{selected | targets: [ambiguous_target, target | targets]}

    assert {:error, %{code: :target_ambiguous}} =
             Discovery.select(%{metadata | packages: [selected | rest]}, selection())
  end

  test "rejects undeclared features before any build can run" do
    assert {:ok, metadata} = Metadata.decode(Jason.encode!(metadata_map()), :web)

    assert {:error, %{code: :feature_invalid, stage: :project_model}} =
             Discovery.select(metadata, %{selection() | features: ["missing"]})
  end

  test "rejects malformed metadata, duplicate identities, and incomplete dependency graphs" do
    assert {:error, %{code: :cargo_metadata_failed}} = Metadata.decode("not-json", :web)

    for mutation <- [
          fn map -> Map.put(map, "workspace_root", "relative") end,
          fn map -> Map.delete(map, "resolve") end,
          fn map -> Map.put(map, "workspace_members", ["missing-package-id"]) end,
          fn map -> Map.put(map, "packages", [hd(map["packages"]), hd(map["packages"])]) end,
          fn map ->
            put_in(map, ["resolve", "nodes", Access.at(0), "deps"], [%{"pkg" => "missing"}])
          end
        ] do
      assert {:error, %{code: :cargo_metadata_failed}} =
               metadata_map() |> mutation.() |> Jason.encode!() |> Metadata.decode(:web)
    end

    map = metadata_map()
    dependency_id = map["resolve"]["nodes"] |> Enum.at(1) |> Map.fetch!("id")
    map = put_in(map, ["resolve", "nodes"], [hd(map["resolve"]["nodes"])])

    assert {:ok, metadata} = Metadata.decode(Jason.encode!(map), :web)
    assert dependency_id in hd(metadata.nodes).dependencies

    assert {:error, %{code: :cargo_metadata_failed}} =
             Discovery.select(metadata, selection())
  end

  defp selection do
    %{
      target: :web,
      package: "sample-ui",
      binary: "sample-web",
      rust_target: "wasm32-unknown-unknown",
      profile: "dev",
      features: ["web"],
      default_features: true
    }
  end

  defp desktop_target do
    %DesktopTarget{
      package: "sample-ui",
      binary: "sample-desktop",
      backend: :canonical,
      features: [],
      default_features: true,
      profiles: %{dev: "dev", release: "release"},
      runtime: %{
        readiness: :ipc_v1,
        startup_timeout_ms: 10_000,
        startup_grace_ms: nil,
        shutdown_timeout_ms: 3_000,
        replacement: :overlap,
        handoff: :enabled
      },
      projection: %{mode: :directory, root: ".rekindle/desktop"},
      toolchain: nil,
      rust_target: nil,
      environment: nil
    }
  end

  defp metadata_map do
    root_id = "path+file:///workspace/client#sample-ui@0.1.0"
    dependency_id = "path+file:///workspace/shared#shared-ui@0.2.0"

    %{
      "workspace_root" => "/workspace/client",
      "target_directory" => "/workspace/client/target",
      "workspace_members" => [root_id],
      "packages" => [
        %{
          "id" => root_id,
          "name" => "sample-ui",
          "version" => "0.1.0",
          "source" => nil,
          "manifest_path" => "/workspace/client/Cargo.toml",
          "features" => %{"default" => ["web"], "web" => []},
          "targets" => [
            %{
              "name" => "sample-web",
              "kind" => ["bin"],
              "crate_types" => ["bin"],
              "src_path" => "/workspace/client/src/bin/web.rs"
            },
            %{
              "name" => "sample-ui",
              "kind" => ["lib"],
              "crate_types" => ["lib"],
              "src_path" => "/workspace/client/src/lib.rs"
            }
          ]
        },
        %{
          "id" => dependency_id,
          "name" => "shared-ui",
          "version" => "0.2.0",
          "source" => nil,
          "manifest_path" => "/workspace/shared/Cargo.toml",
          "features" => %{},
          "targets" => [
            %{
              "name" => "shared-ui",
              "kind" => ["lib"],
              "crate_types" => ["lib"],
              "src_path" => "/workspace/shared/src/lib.rs"
            },
            %{
              "name" => "build-script-build",
              "kind" => ["custom-build"],
              "crate_types" => ["bin"],
              "src_path" => "/workspace/shared/build.rs"
            }
          ]
        }
      ],
      "resolve" => %{
        "nodes" => [
          %{"id" => root_id, "deps" => [%{"name" => "shared_ui", "pkg" => dependency_id}]},
          %{"id" => dependency_id, "deps" => []}
        ]
      }
    }
  end
end
