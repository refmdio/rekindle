defmodule Rekindle.BuildGraphTest do
  use ExUnit.Case, async: true

  alias Rekindle.BuildGraph
  alias Rekindle.BuildGraph.{Identity, Inventory}

  @digest String.duplicate("a", 64)

  test "the graph exposes one stable node order and keyed subset" do
    assert BuildGraph.nodes() == [
             :project_model,
             :cargo_web,
             :cargo_desktop,
             :external_web,
             :external_desktop,
             :bindgen_web,
             :package_web,
             :seal_web,
             :seal_desktop,
             :activate_web,
             :activate_desktop,
             :project_phoenix,
             :project_native
           ]

    assert BuildGraph.keyed_nodes() ==
             ~w[cargo_web cargo_desktop external_web external_desktop bindgen_web package_web seal_web seal_desktop]a

    assert {:ok, 1} = BuildGraph.order(:cargo_web)
    assert :error = BuildGraph.order(:unknown)
  end

  test "inventory admits every regular project input and excludes only declared roots" do
    root = temporary_project()
    write(root, "Cargo.toml", "[workspace]\n")
    write(root, "src/lib.rs", "pub fn app() {}\n")
    write(root, "public/app.css", "body {}\n")
    File.mkdir_p!(Path.join(root, "empty"))
    write(root, ".git/config", "ignored")
    write(root, "_build/output", "ignored")
    write(root, "deps/pkg/lib.ex", "ignored")
    write(root, ".rekindle/cache/output", "ignored")
    write(root, "client/target/debug/app", "ignored")
    write(root, "priv/static/app.js", "ignored")

    assert {:ok, inventory} =
             Inventory.scan(root, ["client/target", "priv/static"])

    assert Enum.map(inventory.direct_inputs, &{&1["kind"], &1["path"]}) == [
             {"empty_directory", "client"},
             {"empty_directory", "empty"},
             {"empty_directory", "priv"},
             {"file", "Cargo.toml"},
             {"file", "public/app.css"},
             {"file", "src/lib.rs"}
           ]

    assert inventory.excluded_roots ==
             ~w[.git .rekindle _build client/target deps priv/static]

    assert Enum.all?(inventory.direct_inputs, fn
             %{"kind" => "file", "sha256" => digest, "size" => size} ->
               digest =~ ~r/\A[0-9a-f]{64}\z/ and size > 0

             %{"kind" => "empty_directory"} ->
               true
           end)

    assert {:ok, target_inputs} = BuildGraph.target_inputs(inventory, [:web, :desktop])
    assert target_inputs.desktop == inventory.direct_inputs
    assert target_inputs.web == inventory.direct_inputs
  end

  test "inventory rejects symlinks, escaping exclusions, and overlapping exclusions" do
    root = temporary_project()
    write(root, "outside", "content")
    File.ln_s!(Path.join(root, "outside"), Path.join(root, "link"))

    assert {:error, %{code: :path_invalid}} = Inventory.scan(root)
    assert {:error, %{code: :path_invalid}} = Inventory.scan(root, ["../outside"])
    assert {:error, %{code: :path_overlap}} = Inventory.scan(root, ["deps/child"])
  end

  test "portable package identity is independent of checkout location" do
    first = Path.join(System.tmp_dir!(), "checkout-a")
    second = Path.join(System.tmp_dir!(), "checkout-b")

    package = %{
      name: "client",
      version: "0.1.0",
      manifest_path: Path.join(first, "client/Cargo.toml")
    }

    assert {:ok, identity} = Identity.portable_package(first, package)

    assert {:ok, ^identity} =
             Identity.portable_package(second, %{
               package
               | manifest_path: Path.join(second, "client/Cargo.toml")
             })

    assert identity == %{
             "kind" => "local",
             "manifest_path" => "client/Cargo.toml",
             "name" => "client",
             "version" => "0.1.0"
           }

    assert {:error, %{code: :path_invalid}} =
             Identity.portable_package(first, %{package | manifest_path: "/outside/Cargo.toml"})
  end

  test "environment identity sorts names and separates secret value domains" do
    assert {:ok, environment} =
             Identity.environment(:toolchain, [
               %{
                 name: "RUSTFLAGS",
                 source: :inherited,
                 value: "-Ctarget-cpu=native",
                 secret: false
               },
               %{name: "TOKEN", source: :host, value: "private", secret: true}
             ])

    assert environment.jcs ==
             ~s({"entries":[{"name":"RUSTFLAGS","secret":false,"source":"inherited","value_digest":"c599569041800a972aa644ff51e1a6cfbc2b8e16018a3ceb7e883366680c1a23"},{"name":"TOKEN","secret":true,"source":"host","value_digest":"56738ba67ebf15b6986f0d156216a353075869dc5b3d43a68d4772db58abbcea"}],"inherit":"toolchain","v":1})

    assert environment.digest ==
             "6a8aa90a6a0e927367896d93f3431f503ac2f7f9cd17c4b144ebfc59fe6f54bc"

    refute environment.preimage =~ "private"

    assert {:error, %{code: :contract_violation}} =
             Identity.environment(:toolchain, [
               %{name: "PATH", source: :inherited, value: "a", secret: false},
               %{name: "PATH", source: :host, value: "b", secret: false}
             ])
  end

  test "Cargo node identity has byte-exact canonical preimages and stable sorting" do
    package = portable_package()
    model = cargo_model(package)
    config = cargo_config(package)

    direct_inputs = [
      %{"kind" => "value", "name" => "z", "value_digest" => @digest},
      %{
        "kind" => "file",
        "path" => "Cargo.lock",
        "file_kind" => "data",
        "sha256" => @digest,
        "size" => 4
      }
    ]

    tools = [
      %{"name" => "rustc", "version" => "rustc 1.90.0\r\n", "content_digest" => nil},
      %{"name" => "cargo", "version" => "cargo 1.90.0\n", "content_digest" => nil}
    ]

    assert {:ok, node} =
             Identity.node_key(
               node: :cargo_web,
               target: :web,
               profile: "dev",
               model_slice: model,
               config: config,
               direct_inputs: direct_inputs,
               predecessors: [],
               tools: tools
             )

    assert Enum.map(node.input["direct_inputs"], & &1["kind"]) == ["file", "value"]
    assert Enum.map(node.input["tools"], & &1["name"]) == ["cargo", "rustc"]
    assert Enum.map(node.input["tools"], & &1["version"]) == ["cargo 1.90.0", "rustc 1.90.0"]

    assert node.model_slice_digest ==
             "d83eec883a51298a19b2b727cab6cf831d1fae503ff9465b5fa3c9f5433f9bee"

    assert node.config_digest ==
             "d8fee6e222bc75049977344b64d8db33adc8b0948244a60ad5eb8aa8429a8edd"

    assert node.key == "1dcb7c2acbe5d01572d953cfc2ded1c276accfdf3377bfd1e6dcd4178bf1dfb5"
    assert node.preimage == "rekindle-node-v1\0" <> Rekindle.CanonicalValue.encode!(node.input)
  end

  test "identity unions reject extra fields, invalid tools, duplicates, and target mismatches" do
    package = portable_package()
    model = cargo_model(package)
    config = cargo_config(package)
    tools = [%{"name" => "cargo", "version" => "cargo", "content_digest" => nil}]

    assert {:error, %{code: :contract_violation}} =
             Identity.node_key(
               node: :cargo_web,
               target: :desktop,
               profile: "dev",
               model_slice: model,
               config: config,
               tools: tools
             )

    assert {:error, %{code: :contract_violation}} =
             Identity.model_slice(Map.put(model, "unexpected", true))

    duplicate = %{"kind" => "value", "name" => "same", "value_digest" => @digest}

    assert {:error, %{code: :contract_violation}} =
             Identity.node_key(
               node: :cargo_web,
               target: :web,
               profile: "dev",
               model_slice: model,
               config: config,
               direct_inputs: [duplicate, duplicate],
               tools: tools
             )
  end

  test "output identity binds metadata and limits executable mode to native nodes" do
    metadata = %{
      "v" => 1,
      "node" => "cargo_desktop",
      "artifact_kind" => "executable",
      "package_identity" => portable_package(),
      "binary" => "desktop",
      "rust_target" => "x86_64-unknown-linux-gnu",
      "profile" => "dev"
    }

    assert {:ok, metadata_identity} =
             Identity.digest("rekindle-node-metadata-v1\0", metadata)

    descriptor = %{
      "v" => 1,
      "node" => "cargo_desktop",
      "files" => [
        %{"path" => "desktop", "sha256" => @digest, "size" => 42, "mode" => "executable"}
      ],
      "metadata_digest" => metadata_identity.digest
    }

    assert {:ok, output} = Identity.output_digest(descriptor, metadata)
    assert output.digest == "71bdf5687ab7993263bdf847ddc4a82ad5e8f767a3dd297aa0c798084c71af59"

    web_descriptor = %{descriptor | "node" => "cargo_web"}

    assert {:error, %{code: :contract_violation}} =
             Identity.output_digest(web_descriptor, metadata)
  end

  test "external plan identity excludes plaintext executable paths and environment values" do
    plan = %Rekindle.ExternalPlan{
      executable: "/opt/backend/bin/build",
      argv: ["--target", "web"],
      cwd: %{root: :client, path: "."},
      env_mode: :replace,
      env_set: [
        %{name: "TOKEN", value: "private", secret: true},
        %{name: "MODE", value: "release", secret: false}
      ],
      diagnostic_mode: :cargo_json,
      timeout_ms: 10_000,
      expected_manifest: "out/manifest.json"
    }

    executable = %{
      path_digest: String.duplicate("b", 64),
      content_sha256: String.duplicate("c", 64),
      size: 512
    }

    assert {:ok, identity} = Identity.external_plan(plan, executable)
    assert identity.digest == "a9898723fd87e88b815646418aff1f609ac0b5a00d6fa07ea0ce92c3b5281d6f"
    refute identity.preimage =~ plan.executable
    refute identity.preimage =~ "private"
    assert Enum.map(identity.value["env_set"], & &1["name"]) == ["MODE", "TOKEN"]

    assert {:error, %{code: :contract_violation}} =
             Identity.external_plan(%{plan | env_set: plan.env_set ++ plan.env_set}, executable)
  end

  test "project model identity is checkout-neutral and rejects undeclared fields" do
    package = portable_package()

    target = %{
      "kind" => "canonical",
      "target" => "web",
      "package_identity" => package,
      "package" => "client",
      "binary" => "web",
      "rust_target" => "wasm32-unknown-unknown",
      "profile" => "dev",
      "features" => [],
      "default_features" => true,
      "toolchain_identity" => cargo_config(package)["fields"]["toolchain"],
      "environment_digest" => @digest,
      "public_root" => "public",
      "hot_styles" => ["public/app.css"],
      "runtime" => nil,
      "projection" => %{"mode" => "phoenix_static", "root" => "priv/static"}
    }

    model = %{
      "v" => 1,
      "application_id" => "demo",
      "client" => "client",
      "targets" => [target],
      "local_packages" => [
        %{
          "package_identity" => package,
          "name" => "client",
          "version" => "0.1.0",
          "manifest_path" => "client/Cargo.toml",
          "source_roots" => ["client/src"],
          "custom_build" => false
        }
      ],
      "cargo_inputs" => [
        %{"path" => "Cargo.lock", "sha256" => @digest, "size" => 100},
        %{"path" => "client/Cargo.toml", "sha256" => @digest, "size" => 200}
      ],
      "compatibility_tuple_id" => @digest
    }

    assert {:ok, identity} = Identity.project_model_digest(model)
    assert identity.digest == "f359d0bc389238a08097ae144bb75dae138caac71b4d53d13bbd5930739d632a"
    refute identity.preimage =~ System.tmp_dir!()

    assert {:error, %{code: :contract_violation}} =
             model |> Map.put("session_id", "ephemeral") |> Identity.project_model_digest()

    invalid = put_in(model, ["targets", Access.at(0), "public_root"], "/absolute")
    assert {:error, %{code: :contract_violation}} = Identity.project_model_digest(invalid)
  end

  defp cargo_model(package) do
    %{
      "v" => 1,
      "node" => "cargo_web",
      "target" => "web",
      "package_identity" => package,
      "binary" => "web",
      "local_package_identities" => [package],
      "has_local_build_script" => false,
      "cargo_input_paths" => ["Cargo.lock", "client/Cargo.toml"],
      "source_roots" => ["client"]
    }
  end

  defp cargo_config(package) do
    %{
      "v" => 1,
      "node" => "cargo_web",
      "target" => "web",
      "fields" => %{
        "package_identity" => package,
        "binary" => "web",
        "rust_target" => "wasm32-unknown-unknown",
        "profile" => "dev",
        "features" => [],
        "default_features" => true,
        "toolchain" => %{
          "kind" => "rustup",
          "name" => "stable",
          "cargo_version" => "cargo 1.90.0",
          "rustc_vv" => "rustc 1.90.0\nhost: x86_64-unknown-linux-gnu",
          "rust_target" => "wasm32-unknown-unknown",
          "components" => ["rust-std"]
        },
        "environment_digest" => @digest
      }
    }
  end

  defp portable_package do
    %{
      "kind" => "local",
      "manifest_path" => "client/Cargo.toml",
      "name" => "client",
      "version" => "0.1.0"
    }
  end

  defp temporary_project do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-inventory-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
