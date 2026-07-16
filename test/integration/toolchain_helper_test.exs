defmodule Rekindle.ToolchainHelperIntegrationTest do
  use ExUnit.Case, async: false

  alias Rekindle.CanonicalValue
  alias Rekindle.Toolchain.{Exec, Frame, Handshake, Helper, Installer, Release, Web}

  @request "0123456789abcdef0123456789abcdef"

  setup_all do
    cache = temp_root("installed")
    source = Path.expand("crates/rekindle-toolchain")
    on_exit(fn -> File.rm_rf!(cache) end)

    assert {:ok, helper} =
             Release.ensure(true, cache_root: cache, source_root: source, offline: true)

    refute String.contains?(helper, "/target/")
    assert File.regular?(helper)
    assert Bitwise.band(File.stat!(helper).mode, 0o100) != 0
    %{helper: helper}
  end

  test "exec-v1 negotiates, preserves binary streams, and reports a confirmed exit", %{
    helper: helper
  } do
    executable = System.find_executable("printf") |> Path.expand()

    assert {:ok, spawn, state} =
             Exec.spawn_request(
               request_id: @request,
               executable: executable,
               argv: ["%s", "hello world"],
               cwd: System.tmp_dir!(),
               env_mode: :replace,
               terminate_grace_ms: 100,
               kill_grace_ms: 100
             )

    assert {:ok, terminal, "hello world", ""} =
             Helper.run_exec(helper, spawn, state, timeout_ms: 5_000)

    assert terminal.outcome == :exited
    assert terminal.code == 0
    assert terminal.cleanup == :confirmed
    assert terminal.stdout_bytes == 11
  end

  test "exec-v1 timeout terminates and reaps the complete descendant process group", %{
    helper: helper
  } do
    root = temp_root("exec")
    script = Path.join(root, "descendants")

    File.mkdir_p!(root)
    File.write!(script, "#!/bin/sh\nsleep 30 &\necho $!\nwait\n")
    File.chmod!(script, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, spawn, state} =
             Exec.spawn_request(
               request_id: @request,
               executable: script,
               cwd: root,
               terminate_grace_ms: 100,
               kill_grace_ms: 500
             )

    assert {:ok, terminal, stdout, ""} =
             Helper.run_exec(helper, spawn, state,
               timeout_ms: 150,
               cleanup_timeout_ms: 2_000
             )

    descendant = stdout |> String.trim() |> String.to_integer()
    assert terminal.outcome == :signaled
    assert terminal.cleanup == :confirmed
    refute process_exists?(descendant)
  end

  test "guardian removes the descendant group when the helper dies after started", %{
    helper: helper
  } do
    root = temp_root("helper-death")
    script = Path.join(root, "descendants")
    descendant_file = Path.join(root, "descendant.pid")
    File.mkdir_p!(root)
    File.write!(script, "#!/bin/sh\nsleep 30 &\necho $! > #{descendant_file}\nwait\n")
    File.chmod!(script, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, spawn, state} =
             Exec.spawn_request(
               request_id: @request,
               executable: script,
               cwd: root,
               terminate_grace_ms: 100,
               kill_grace_ms: 500
             )

    result =
      Helper.run_exec(helper, spawn, state,
        timeout_ms: 5_000,
        cleanup_timeout_ms: 2_000,
        started_hook: fn port, _state ->
          assert wait_file(descendant_file, 1_000)
          {:os_pid, helper_pid} = Port.info(port, :os_pid)
          {_output, 0} = System.cmd("/usr/bin/kill", ["-KILL", Integer.to_string(helper_pid)])
        end
      )

    assert {:error, _reason} = result
    descendant = descendant_file |> File.read!() |> String.trim() |> String.to_integer()
    assert wait_process_absent(descendant, 2_000)
  end

  test "guardian closes the ownership race before started is admitted", %{
    helper: helper
  } do
    root = temp_root("pre-start")
    script = Path.join(root, "leader")
    leader_file = Path.join(root, "leader.pid")
    File.mkdir_p!(root)
    File.write!(script, "#!/bin/sh\necho $$ > #{leader_file}\nsleep 30\n")
    File.chmod!(script, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    port = open_helper(helper, "exec-v1")
    negotiate(port, "exec-v1")

    assert {:ok, spawn, _state} =
             Exec.spawn_request(
               request_id: @request,
               executable: script,
               cwd: root,
               terminate_grace_ms: 100,
               kill_grace_ms: 500
             )

    assert {:ok, encoded} = Frame.encode(spawn)
    assert Port.command(port, encoded)
    assert wait_file(leader_file, 1_000)
    {:os_pid, helper_pid} = Port.info(port, :os_pid)
    {_output, 0} = System.cmd("/usr/bin/kill", ["-KILL", Integer.to_string(helper_pid)])
    assert_receive {^port, {:exit_status, _status}}, 1_000

    leader = leader_file |> File.read!() |> String.trim() |> String.to_integer()
    assert wait_process_absent(leader, 1_000)
  end

  test "exec-v1 bounds retained binary output and reports discarded bytes", %{helper: helper} do
    executable = System.find_executable("head") |> Path.expand()

    assert {:ok, spawn, state} =
             Exec.spawn_request(
               request_id: @request,
               executable: executable,
               argv: ["-c", "1100000", "/dev/zero"],
               cwd: System.tmp_dir!(),
               terminate_grace_ms: 100,
               kill_grace_ms: 100
             )

    assert {:ok, terminal, stdout, ""} =
             Helper.run_exec(helper, spawn, state, timeout_ms: 5_000)

    assert byte_size(stdout) == 1_048_576
    assert terminal.stdout_bytes == 1_048_576
    assert terminal.discarded_stdout == 51_424
    assert terminal.cleanup == :confirmed
  end

  test "the real helper rejects compatibility mismatch and noncanonical hello", %{
    helper: helper
  } do
    expected = %{Helper.compatibility() | "helper_version" => "9.9.9"}
    host = Installer.host() |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    hello = Handshake.hello("web-v1", expected, host)
    port = open_helper(helper, "web-v1")
    assert {:ok, encoded} = Frame.encode(hello)
    assert Port.command(port, encoded)

    assert {:ok, %{"type" => "hello_error", "code" => "version_mismatch"}, <<>>} =
             receive_frame(port, <<>>)

    assert_receive {^port, {:exit_status, 2}}, 1_000

    port = open_helper(helper, "web-v1")
    request_id = String.duplicate("0", 32)
    noncanonical = ~s({"v":1, "type":"hello","request_id":"#{request_id}","payload_len":0})
    assert Port.command(port, <<byte_size(noncanonical)::32, noncanonical::binary>>)
    assert_receive {^port, {:exit_status, 2}}, 1_000
    refute_receive {^port, {:data, _bytes}}, 50
  end

  test "web-v1 applies every debug and source-map policy combination", %{helper: helper} do
    root = temp_root("web-source-maps")
    input = Path.join(root, "input")
    File.mkdir_p!(input)
    File.write!(Path.join(input, "app.wasm"), wasm_module())
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, input_root} = Web.root(input, :read, id: id(10))
    assert {:ok, wasm} = Web.file(input_root, "app.wasm")

    for {debug, source_maps, number} <- [
          {false, :none, 11},
          {true, :none, 12},
          {false, :external, 13},
          {true, :external, 14}
        ] do
      output = Path.join(root, "output-#{number}")
      File.mkdir_p!(output)
      assert {:ok, output_root} = Web.prepare_output_root(output, id: id(number))

      assert {:ok, request, state} =
               bindgen_operation(input_root, wasm, output_root, limits(),
                 debug: debug,
                 source_maps: source_maps
               )

      assert {:ok, %{"type" => "operation_ok", "files" => files}, []} =
               Helper.run_web(helper, request, state)

      paths = Enum.map(files, & &1["path"])
      javascript = File.read!(Path.join(output, "app.js"))

      if source_maps == :external do
        assert "app.js.map" in paths
        assert String.ends_with?(javascript, "//# sourceMappingURL=app.js.map\n")
        source_map = output |> Path.join("app.js.map") |> File.read!() |> Jason.decode!()

        assert Map.keys(source_map) |> Enum.sort() ==
                 ~w[file mappings names sources sourcesContent version]

        assert source_map["version"] == 3
        assert source_map["file"] == "app.js"
        assert source_map["sources"] == ["wasm-bindgen://generated/app.js"]
        assert source_map["names"] == []
        assert [mapped_javascript] = source_map["sourcesContent"]
        refute String.contains?(mapped_javascript, "sourceMappingURL=")
        assert source_map["mappings"] != ""
      else
        refute "app.js.map" in paths
        refute String.contains?(javascript, "sourceMappingURL=")
      end
    end
  end

  test "web-v1 rejects real bindgen schema, identity, Wasm, and limit failures", %{
    helper: helper
  } do
    root = temp_root("web-errors")
    on_exit(fn -> File.rm_rf!(root) end)

    cases = [
      {:incompatible_schema, wasm_module(), "incompatible_schema",
       fn request, _path ->
         %{request | "expected_wasm_bindgen" => "9.9.9"}
       end},
      {:invalid_debug, wasm_module(), "invalid_request",
       fn request, _path ->
         %{request | "debug" => "false"}
       end},
      {:root_substitution, wasm_module(), "invalid_request",
       fn request, _path ->
         put_in(request, ["input_wasm", "root_id"], id(99))
       end},
      {:asset_escape, wasm_module(), "asset_escape",
       fn request, _path ->
         put_in(request, ["input_wasm", "path"], "../app.wasm")
       end},
      {:invalid_wasm, "not wasm", "invalid_wasm", fn request, _path -> request end},
      {:bindgen_failed, wasm_module() <> <<1, 128>>, "bindgen_failed",
       fn request, _path ->
         request
       end},
      {:input_changed, wasm_module(), "input_changed",
       fn request, path ->
         File.write!(path, wasm_module() <> <<0>>)
         request
       end},
      {:output_limit, wasm_module(), "output_limit",
       fn request, _path ->
         put_in(request, ["limits", "max_output_bytes"], 1)
       end}
    ]

    for {{name, bytes, expected_code, mutate}, number} <- Enum.with_index(cases, 20) do
      input = Path.join(root, "#{name}-input")
      output = Path.join(root, "#{name}-output")
      Enum.each([input, output], &File.mkdir_p!/1)
      wasm_path = Path.join(input, "app.wasm")
      File.write!(wasm_path, bytes)
      assert {:ok, input_root} = Web.root(input, :read, id: id(number))
      assert {:ok, wasm} = Web.file(input_root, "app.wasm")
      assert {:ok, output_root} = Web.prepare_output_root(output, id: id(number + 100))
      assert {:ok, request, state} = bindgen_operation(input_root, wasm, output_root, limits())
      request = mutate.(request, wasm_path)

      assert {:ok, %{"type" => "operation_error", "code" => ^expected_code}, []} =
               Helper.run_web(helper, request, state)
    end
  end

  test "web-v1 classifies real package import, collision, and I/O failures", %{helper: helper} do
    root = temp_root("web-package-errors")
    bindgen = Path.join(root, "bindgen")
    public_html = Path.join(root, "public-html")
    public_collision = Path.join(root, "public-collision")
    Enum.each([bindgen, public_html, public_collision], &File.mkdir_p!/1)
    File.write!(Path.join(bindgen, "app.js"), "export default async function() {}\n")
    File.write!(Path.join(bindgen, "app_bg.wasm"), wasm_module())
    File.write!(Path.join(public_html, "index.html"), "<!doctype html>")
    File.write!(Path.join(public_collision, "app.js"), "collision")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, bindgen_root} = Web.root(bindgen, :read, id: id(40))

    bindgen_files =
      Enum.map(["app.js", "app_bg.wasm"], fn path ->
        {:ok, descriptor} = Web.file(bindgen_root, path)
        descriptor
      end)

    assert {:ok, html_root} = Web.root(public_html, :read, id: id(41))
    assert {:ok, html} = Web.file(html_root, "index.html")
    assert {:ok, collision_root} = Web.root(public_collision, :read, id: id(42))
    assert {:ok, collision} = Web.file(collision_root, "app.js")

    cases = [
      {:unsupported_import, html_root, [html], "unsupported_import"},
      {:asset_collision, collision_root, [collision], "asset_collision"},
      {:io_failed, nil, [], "io_failed"}
    ]

    for {{name, public_root, public_files, expected_code}, number} <-
          Enum.with_index(cases, 43) do
      output = Path.join(root, Atom.to_string(name))
      File.mkdir_p!(output)
      assert {:ok, output_root} = Web.prepare_output_root(output, id: id(number))

      assert {:ok, request, state} =
               package_operation(
                 bindgen_root,
                 bindgen_files,
                 public_root,
                 public_files,
                 output_root
               )

      if name == :io_failed, do: File.chmod!(output, 0o500)

      assert {:ok, %{"type" => "operation_error", "code" => ^expected_code}, []} =
               Helper.run_web(helper, request, state)

      if name == :io_failed, do: File.chmod!(output, 0o700)
    end
  end

  test "the BEAM client rejects forged success and post-terminal helper frames", %{
    helper: _helper
  } do
    root = temp_root("web-forged-helper")
    input = Path.join(root, "input")
    output = Path.join(root, "output")
    Enum.each([input, output], &File.mkdir_p!/1)
    File.write!(Path.join(input, "app.wasm"), wasm_module())
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, input_root} = Web.root(input, :read, id: id(50))
    assert {:ok, wasm} = Web.file(input_root, "app.wasm")
    assert {:ok, output_root} = Web.prepare_output_root(output, id: id(51))
    assert {:ok, request, state} = bindgen_operation(input_root, wasm, output_root, limits())

    File.write!(Path.join(output, "app.js"), "export default async function() {}\n")
    File.write!(Path.join(output, "app_bg.wasm"), wasm_module())

    files =
      Enum.map(["app.js", "app_bg.wasm"], fn path ->
        {:ok, descriptor} = Web.file(output_root, path)
        descriptor
      end)

    terminal = bindgen_terminal(files)
    forged = put_in(terminal, ["files", Access.at(0), "sha256"], String.duplicate("0", 64))
    forged_helper = fake_web_helper(root, "forged", forged)
    assert {:error, :helper_protocol} = Helper.run_web(forged_helper, request, state)

    extra_helper = fake_web_helper(root, "extra", terminal, extra: true)
    assert {:error, :post_terminal_frame} = Helper.run_web(extra_helper, request, state)

    internal = %{
      "v" => 1,
      "type" => "operation_error",
      "payload_len" => 0,
      "op" => "bindgen_web",
      "code" => "internal",
      "message" => "controlled internal failure",
      "diagnostics" => []
    }

    internal_helper = fake_web_helper(root, "internal", internal)

    assert {:ok, %{"type" => "operation_error", "code" => "internal"}, []} =
             Helper.run_web(internal_helper, request, state)
  end

  test "web-v1 derives the exact transitive JavaScript and CSS graph from member bytes", %{
    helper: helper
  } do
    root = temp_root("web-graph")
    bindgen = Path.join(root, "bindgen")
    public = Path.join(root, "public")
    output = Path.join(root, "output")
    Enum.each([bindgen, public, output], &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf!(root) end)

    write_tree(bindgen, %{
      "app.js" => """
      import "./modules/static.js";
      export { value } from "./modules/exported.js";
      const lazy = import("./modules/lazy.js");
      const wasm = new URL("./app_bg.wasm", import.meta.url);
      export default async function init() { return [lazy, wasm]; }
      //# sourceMappingURL=app.js.map
      """,
      "app.js.map" => ~s({"version":3}),
      "app_bg.wasm" => wasm_module()
    })

    write_tree(public, %{
      "modules/static.js" => ~s(import "./nested.js"; export const value = 1;),
      "modules/exported.js" => "export const value = 2;",
      "modules/lazy.js" => "export const value = 3;",
      "modules/nested.js" => "export const value = 4;",
      "styles/app.css" => """
      @import "./theme.css";
      .hero { background: url("./image.png"); mask: url("https://cdn.example/mask.svg"); }
      /*# sourceMappingURL=app.css.map */
      """,
      "styles/theme.css" => ~s|@import url("https://cdn.example/theme.css");|,
      "styles/image.png" => <<1, 2, 3>>,
      "styles/app.css.map" => ~s({"version":3})
    })

    assert {:ok, bindgen_root} = Web.root(bindgen, :read, id: id(70))
    assert {:ok, public_root} = Web.root(public, :read, id: id(71))
    bindgen_files = web_files(bindgen_root, Map.keys(read_tree(bindgen)))
    public_files = web_files(public_root, Map.keys(read_tree(public)))
    assert {:ok, output_root} = Web.prepare_output_root(output, id: id(72))

    assert {:ok, request, state} =
             package_operation(
               bindgen_root,
               bindgen_files,
               public_root,
               public_files,
               output_root,
               hot_styles: ["styles/app.css"]
             )

    assert {:ok, %{"type" => "operation_ok"} = terminal, []} =
             Helper.run_web(helper, request, state)

    manifest =
      output
      |> Path.join("rekindle-web-manifest-v1.json")
      |> File.read!()
      |> Jason.decode!()

    expected = [
      {"app.js", "app.js.map", "source_map"},
      {"app.js", "app_bg.wasm", "wasm_url"},
      {"app.js", "modules/exported.js", "esm_import"},
      {"app.js", "modules/lazy.js", "dynamic_import"},
      {"app.js", "modules/static.js", "esm_import"},
      {"entry.js", "app.js", "dynamic_import"},
      {"entry.js", "app_bg.wasm", "wasm_url"},
      {"entry.js", "styles/app.css", "css_url"},
      {"modules/static.js", "modules/nested.js", "esm_import"},
      {"styles/app.css", "https://cdn.example/mask.svg", "asset_url"},
      {"styles/app.css", "styles/app.css.map", "source_map"},
      {"styles/app.css", "styles/image.png", "asset_url"},
      {"styles/app.css", "styles/theme.css", "css_url"},
      {"styles/theme.css", "https://cdn.example/theme.css", "css_url"}
    ]

    assert Enum.map(manifest["edges"], &{&1["from"], &1["to"], &1["kind"]}) ==
             Enum.sort(expected)

    assert :ok = Web.revalidate_manifest(output_root, terminal)

    forged = update_in(manifest["edges"], &tl/1)
    forged = put_in(forged["manifest_digest"], web_manifest_digest(forged))

    File.write!(
      Path.join(output, "rekindle-web-manifest-v1.json"),
      CanonicalValue.encode!(forged)
    )

    assert {:error, :manifest_changed} =
             Web.revalidate_manifest(output_root, %{
               "artifact_id" => terminal["artifact_id"],
               "manifest_digest" => forged["manifest_digest"]
             })
  end

  test "web-v1 rejects forbidden and unresolved JavaScript and CSS references", %{
    helper: helper
  } do
    root = temp_root("web-forbidden-graph")
    on_exit(fn -> File.rm_rf!(root) end)

    cases = [
      {"bare", ~s(import "react";)},
      {"npm", ~s(import "npm:react";)},
      {"parent", ~s(import "../outside.js";)},
      {"data", ~s|new URL("data:text/plain,x", import.meta.url);|},
      {"javascript", ~s|new URL("javascript:alert(1)", import.meta.url);|},
      {"filesystem", ~s|new URL("file:///tmp/member", import.meta.url);|},
      {"absolute", ~s(import "/absolute.js";)},
      {"unresolved", ~s(import "./missing.js";)},
      {"dynamic", "const path = './missing.js'; import(path);"}
    ]

    for {{label, reference}, number} <- Enum.with_index(cases, 80) do
      bindgen = Path.join(root, "#{label}-bindgen")
      output = Path.join(root, "#{label}-output")
      Enum.each([bindgen, output], &File.mkdir_p!/1)

      write_tree(bindgen, %{
        "app.js" => reference <> "\nexport default async function init() {}\n",
        "app_bg.wasm" => wasm_module()
      })

      assert {:ok, bindgen_root} = Web.root(bindgen, :read, id: id(number))
      bindgen_files = web_files(bindgen_root, ["app.js", "app_bg.wasm"])
      assert {:ok, output_root} = Web.prepare_output_root(output, id: id(number + 100))

      assert {:ok, request, state} =
               package_operation(bindgen_root, bindgen_files, nil, [], output_root)

      assert {:ok, %{"type" => "operation_error", "code" => "unsupported_import"}, []} =
               Helper.run_web(helper, request, state)
    end

    bindgen = Path.join(root, "css-bindgen")
    public = Path.join(root, "css-public")

    write_tree(bindgen, %{
      "app.js" => "export default async function init() {}",
      "app_bg.wasm" => wasm_module()
    })

    for {reference, number} <-
          Enum.with_index(
            [
              ~s(@import "../outside.css";),
              ~s|body { background: url("data:image/png,x"); }|,
              ~s|body { background: url("javascript:alert(1)"); }|,
              ~s|body { background: url("file:///tmp/member"); }|,
              ~s|body { background: url("./missing.png"); }|
            ],
            200
          ) do
      output = Path.join(root, "css-output-#{number}")
      File.rm_rf!(public)
      File.mkdir_p!(output)
      write_tree(public, %{"styles/app.css" => reference})
      assert {:ok, bindgen_root} = Web.root(bindgen, :read, id: id(number))
      assert {:ok, public_root} = Web.root(public, :read, id: id(number + 100))
      assert {:ok, output_root} = Web.prepare_output_root(output, id: id(number + 200))

      assert {:ok, request, state} =
               package_operation(
                 bindgen_root,
                 web_files(bindgen_root, ["app.js", "app_bg.wasm"]),
                 public_root,
                 web_files(public_root, ["styles/app.css"]),
                 output_root,
                 hot_styles: ["styles/app.css"]
               )

      assert {:ok, %{"type" => "operation_error", "code" => "unsupported_import"}, []} =
               Helper.run_web(helper, request, state)
    end
  end

  test "web-v1 performs bindgen, package, verify, and detects post-package tampering", %{
    helper: helper
  } do
    root = temp_root("web")
    input = Path.join(root, "input")
    bindgen_output = Path.join(root, "bindgen")
    package_output = Path.join(root, "package")
    Enum.each([input, bindgen_output, package_output], &File.mkdir_p!/1)
    File.write!(Path.join(input, "app.wasm"), <<0, 97, 115, 109, 1, 0, 0, 0>>)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, input_root} = Web.root(input, :read, id: id(1))
    assert {:ok, wasm} = Web.file(input_root, "app.wasm")
    assert {:ok, bindgen_root} = Web.prepare_output_root(bindgen_output, id: id(2))
    limits = limits()

    marker = Path.join(bindgen_output, Web.marker())
    File.chmod!(marker, 0o700)

    assert {:ok, rejected_request, rejected_state} =
             bindgen_operation(input_root, wasm, bindgen_root, limits)

    assert {:ok, %{"type" => "operation_error", "code" => "invalid_request"}, []} =
             Helper.run_web(helper, rejected_request, rejected_state)

    File.chmod!(marker, 0o600)

    assert {:ok, request, state} =
             bindgen_operation(input_root, wasm, bindgen_root, limits,
               debug: true,
               source_maps: :external
             )

    assert {:ok, %{"type" => "operation_ok", "op" => "bindgen_web"} = bound, []} =
             Helper.run_web(helper, request, state)

    assert {:ok, bindgen_read} = Web.root(bindgen_output, :read, id: id(3))

    bindgen_files =
      Enum.map(bound["files"], fn descriptor ->
        {:ok, descriptor} = Web.file(bindgen_read, descriptor["path"])
        descriptor
      end)

    assert {:ok, package_root} = Web.prepare_output_root(package_output, id: id(4))

    assert {:ok, request, state} =
             Web.operation(
               "package_web",
               %{
                 bindgen_root: bindgen_read,
                 bindgen_files: bindgen_files,
                 public_root: nil,
                 public_files: [],
                 bootstrap_template: Web.bootstrap_template(),
                 output_root: package_root,
                 manifest_base: manifest_base(),
                 limits: limits
               },
               request_id: @request
             )

    assert {:ok, %{"type" => "operation_ok", "op" => "package_web"} = package, []} =
             Helper.run_web(helper, request, state)

    assert :ok = Web.revalidate_files(package_root, package["files"])

    manifest_value =
      package_output
      |> Path.join("rekindle-web-manifest-v1.json")
      |> File.read!()
      |> Jason.decode!()

    javascript_member = Enum.find(manifest_value["members"], &(&1["role"] == "javascript"))
    assert javascript_member["source_map"] == javascript_member["path"] <> ".map"

    assert Enum.any?(manifest_value["edges"], fn edge ->
             edge == %{
               "from" => javascript_member["path"],
               "to" => javascript_member["source_map"],
               "kind" => "source_map"
             }
           end)

    assert {:ok, artifact_root} = Web.root(package_output, :read, id: id(5))
    assert {:ok, manifest} = Web.file(artifact_root, "rekindle-web-manifest-v1.json")

    assert {:ok, request, state} =
             Web.operation(
               "verify_web",
               %{
                 artifact_root: artifact_root,
                 manifest: manifest,
                 expected_manifest_digest: package["manifest_digest"],
                 limits: limits
               },
               request_id: @request
             )

    assert {:ok, %{"type" => "operation_ok", "op" => "verify_web"} = verified, []} =
             Helper.run_web(helper, request, state)

    assert verified["artifact_id"] == package["artifact_id"]

    member =
      package_output
      |> Path.join("members/**/*")
      |> Path.wildcard()
      |> Enum.find(&File.regular?/1)

    File.write!(member, "tampered")

    assert {:ok, %{"type" => "operation_error", "code" => "input_changed"}, []} =
             Helper.run_web(helper, request, state)
  end

  defp limits do
    {:ok, limits} =
      Web.limits(
        max_files: 100,
        max_input_bytes: 10_000_000,
        max_output_bytes: 10_000_000,
        deadline_ms: 30_000
      )

    limits
  end

  defp bindgen_operation(input_root, wasm, output_root, limits, options \\ []) do
    Web.operation(
      "bindgen_web",
      %{
        input_root: input_root,
        input_wasm: wasm,
        output_root: output_root,
        output_stem: "app",
        debug: Keyword.get(options, :debug, false),
        source_maps: Keyword.get(options, :source_maps, :none),
        expected_wasm_bindgen: "0.2.121",
        limits: limits
      },
      request_id: @request
    )
  end

  defp package_operation(
         bindgen_root,
         bindgen_files,
         public_root,
         public_files,
         output_root,
         options \\ []
       ) do
    Web.operation(
      "package_web",
      %{
        bindgen_root: bindgen_root,
        bindgen_files: bindgen_files,
        public_root: public_root,
        public_files: public_files,
        bootstrap_template: Web.bootstrap_template(),
        output_root: output_root,
        manifest_base: manifest_base(Keyword.get(options, :hot_styles, [])),
        limits: limits()
      },
      request_id: @request
    )
  end

  defp bindgen_terminal(files) do
    %{
      "v" => 1,
      "type" => "operation_ok",
      "payload_len" => 0,
      "op" => "bindgen_web",
      "files" => files,
      "javascript_entry" => "app.js",
      "wasm" => "app_bg.wasm"
    }
  end

  defp fake_web_helper(root, label, terminal, options \\ []) do
    python = System.find_executable("python3") || raise "python3 is required for helper fixtures"
    path = Path.join(root, "fake-helper-#{label}")
    terminal = CanonicalValue.encode!(terminal)
    extra = if Keyword.get(options, :extra, false), do: "write_frame(terminal)", else: ""

    File.write!(
      path,
      """
      ##!#{python}
      import json
      import struct
      import sys

      def read_frame():
          length_bytes = sys.stdin.buffer.read(4)
          if len(length_bytes) != 4:
              raise SystemExit(2)
          length = struct.unpack(">I", length_bytes)[0]
          header = json.loads(sys.stdin.buffer.read(length))
          payload_length = header.get("payload_len", 0)
          if payload_length:
              sys.stdin.buffer.read(payload_length)
          return header

      def write_frame(header):
          body = json.dumps(header, sort_keys=True, separators=(",", ":")).encode()
          sys.stdout.buffer.write(struct.pack(">I", len(body)) + body)
          sys.stdout.buffer.flush()

      hello = read_frame()
      write_frame({
          "v": 1,
          "type": "hello_ok",
          "request_id": hello["request_id"],
          "payload_len": 0,
          "session_nonce": hello["session_nonce"],
          "mode": hello["mode"],
          "actual": hello["expected"],
          "host": hello["host"]
      })
      operation = read_frame()
      terminal = json.loads(#{inspect(terminal)})
      terminal["request_id"] = operation["request_id"]
      write_frame(terminal)
      #{extra}
      """
      |> String.replace_leading("##!", "#!")
    )

    File.chmod!(path, 0o700)
    path
  end

  defp wasm_module, do: <<0, 97, 115, 109, 1, 0, 0, 0>>

  defp manifest_base(hot_styles \\ []) do
    %{
      rekindle_version: "0.1.0",
      application_id: "sample_app",
      target: "web",
      build: %{
        build_key: String.duplicate("a", 64),
        profile: "dev",
        package: "sample_app_ui",
        binary: "sample_app-web",
        features: ["web"]
      },
      producer: %{
        kind: "canonical_web",
        rustc: "1.95.0",
        cargo: "1.95.0",
        rust_target: "wasm32-unknown-unknown",
        gpui_revision: String.duplicate("b", 40),
        helper_version: "0.1.0",
        helper_protocol: 1,
        wasm_bindgen: "0.2.121",
        compatibility_tuple_id: "test-linux-x86_64"
      },
      host_requirements: %{secure_context: true, webgpu: true},
      hot_styles: hot_styles
    }
  end

  defp write_tree(root, files) do
    Enum.each(files, fn {path, bytes} ->
      destination = Path.join(root, path)
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, bytes)
    end)
  end

  defp read_tree(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Map.new(&{Path.relative_to(&1, root), File.read!(&1)})
  end

  defp web_files(root, paths) do
    paths
    |> Enum.sort()
    |> Enum.map(fn path ->
      {:ok, descriptor} = Web.file(root, path)
      descriptor
    end)
  end

  defp web_manifest_digest(manifest) do
    :crypto.hash(
      :sha256,
      [
        "rekindle-web-manifest-v1\0",
        manifest |> Map.delete("manifest_digest") |> CanonicalValue.encode!()
      ]
    )
    |> Base.encode16(case: :lower)
  end

  defp id(number),
    do: number |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")

  defp process_exists?(pid) do
    case File.read("/proc/#{pid}/status") do
      {:ok, status} when is_binary(status) ->
        not String.contains?(status, "\nState:\tZ")

      _ ->
        case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
          {_, 0} -> true
          {_, _} -> false
        end
    end
  end

  defp open_helper(helper, mode) do
    Port.open(
      {:spawn_executable, String.to_charlist(helper)},
      [:binary, :exit_status, :use_stdio, args: [mode]]
    )
  end

  defp receive_frame(port, buffer) do
    case Frame.decode(buffer) do
      {:ok, header, payload, _remaining} ->
        {:ok, header, payload}

      {:more, _} ->
        receive do
          {^port, {:data, bytes}} -> receive_frame(port, buffer <> bytes)
        after
          1_000 -> {:error, :timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp negotiate(port, mode) do
    host = Installer.host() |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    hello = Handshake.hello(mode, Helper.compatibility(), host)
    {:ok, encoded} = Frame.encode(hello)
    true = Port.command(port, encoded)
    {:ok, %{"type" => "hello_ok"}, <<>>} = receive_frame(port, <<>>)
    :ok
  end

  defp wait_file(path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    cond do
      File.regular?(path) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        wait_file(path, deadline - System.monotonic_time(:millisecond))
    end
  end

  defp wait_process_absent(pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    cond do
      not process_exists?(pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        wait_process_absent(pid, deadline - System.monotonic_time(:millisecond))
    end
  end

  defp temp_root(label) do
    Path.join(
      System.tmp_dir!(),
      "rekindle-helper-#{label}-#{System.unique_integer([:positive])}"
    )
  end
end
