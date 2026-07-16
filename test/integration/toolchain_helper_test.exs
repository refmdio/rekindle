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

  test "helper launch rejects an inode replacement after qualification", %{helper: helper} do
    assert {:ok, spawn, state} =
             Exec.spawn_request(
               request_id: @request,
               executable: "/usr/bin/true",
               cwd: System.tmp_dir!(),
               terminate_grace_ms: 100,
               kill_grace_ms: 100
             )

    replacement = helper <> ".replacement"
    admitted = helper <> ".admitted"
    File.cp!(helper, replacement)
    File.chmod!(replacement, 0o700)

    hook = fn ->
      File.rename!(helper, admitted)
      File.rename!(replacement, helper)
      :ok
    end

    try do
      assert {:error, :helper_missing} =
               Helper.run_exec(helper, spawn, state, before_spawn: hook)
    after
      File.rm(helper)
      File.rename(admitted, helper)
      File.rm(replacement)
    end
  end

  test "helper launch executes immutable admitted bytes across a same-inode content ABA", %{
    helper: helper
  } do
    root = temp_root("helper-content-aba")
    marker = Path.join(root, "malicious-ran")
    trusted = File.read!(helper)
    original_inode = File.stat!(helper).inode
    malicious = padded_script("printf malicious > #{marker}\nexit 0\n", byte_size(trusted))
    on_exit(fn -> File.rm_rf!(root) end)

    assert byte_size(malicious) == byte_size(trusted)

    assert {:ok, spawn, state} =
             Exec.spawn_request(
               request_id: @request,
               executable: "/usr/bin/true",
               cwd: System.tmp_dir!(),
               terminate_grace_ms: 100,
               kill_grace_ms: 100
             )

    around_spawn = fn _authority, launch_path, launch ->
      assert String.contains?(launch_path, ["/proc/", "/dev/fd/"])
      File.write!(helper, malicious)
      assert File.stat!(helper).inode == original_inode

      result = launch.()
      Process.sleep(100)

      File.write!(helper, trusted)
      assert File.stat!(helper).inode == original_inode
      result
    end

    try do
      assert {:ok, terminal, "", ""} =
               Helper.run_exec(helper, spawn, state,
                 around_spawn: around_spawn,
                 timeout_ms: 5_000
               )

      assert terminal.outcome == :exited
      assert terminal.code == 0
      refute File.exists?(marker)
    after
      File.write!(helper, trusted)
      File.chmod!(helper, 0o700)
    end

    assert File.stat!(helper).inode == original_inode
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

  test "zero terminate grace escalates immediately and reaps the process group", %{
    helper: helper
  } do
    root = temp_root("zero-terminate-grace")
    script = Path.join(root, "ignore-term")
    ready = Path.join(root, "ready")
    File.mkdir_p!(root)

    File.write!(
      script,
      "#!/bin/sh\ntrap '' TERM\nprintf ready > #{ready}\nwhile :; do sleep 1; done\n"
    )

    File.chmod!(script, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, spawn, state} =
             Exec.spawn_request(
               request_id: @request,
               executable: script,
               cwd: root,
               terminate_grace_ms: 0,
               kill_grace_ms: 500
             )

    started_hook = fn _port, _state ->
      assert wait_file(ready, 1_000)
      Process.put(:zero_terminate_ready_at, System.monotonic_time(:millisecond))
    end

    assert {:ok, terminal, "", ""} =
             Helper.run_exec(helper, spawn, state,
               timeout_ms: 200,
               cleanup_timeout_ms: 1_000,
               started_hook: started_hook
             )

    elapsed = System.monotonic_time(:millisecond) - Process.get(:zero_terminate_ready_at)
    assert terminal.outcome == :signaled
    assert terminal.signal == 9
    assert terminal.cleanup == :confirmed
    assert elapsed < 1_000
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

  test "the real helper admits the exact hello schema and exposes every mismatch class", %{
    helper: helper
  } do
    host = Installer.host() |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    expected = Helper.compatibility()
    nonce = String.duplicate("a", 64)

    hello = %{
      "v" => 1,
      "type" => "hello",
      "request_id" => @request,
      "payload_len" => 0,
      "session_nonce" => nonce,
      "mode" => "web-v1",
      "expected" => expected,
      "host" => host
    }

    invalid_hellos = [
      update_in(hello, ["expected"], &Map.delete(&1, "helper_version")),
      put_in(hello, ["expected", "extra"], 1),
      put_in(hello, ["expected", "toolframe"], "1"),
      update_in(hello, ["host"], &Map.delete(&1, "arch")),
      put_in(hello, ["host", "extra"], "value"),
      put_in(hello, ["host", "os"], 1)
    ]

    mismatch_hellos = [
      {put_in(hello, ["expected", "toolframe"], 2), "protocol_mismatch"},
      {put_in(hello, ["expected", "wasm_bindgen_schema"], "0.0.0"), "schema_mismatch"},
      {put_in(hello, ["expected", "helper_version"], "9.9.9"), "version_mismatch"},
      {put_in(hello, ["host", "arch"], "other"), "host_mismatch"}
    ]

    for invalid <- invalid_hellos do
      assert_hello_error(helper, invalid, "invalid_hello", expected, host)
    end

    for {mismatch, code} <- mismatch_hellos do
      assert_hello_error(helper, mismatch, code, expected, host)
    end

    port = open_helper(helper, "web-v1")
    assert {:ok, encoded} = Frame.encode(hello)
    assert Port.command(port, encoded)

    assert {:ok,
            %{
              "v" => 1,
              "type" => "hello_ok",
              "request_id" => @request,
              "payload_len" => 0,
              "session_nonce" => ^nonce,
              "mode" => "web-v1",
              "actual" => ^expected,
              "host" => ^host
            }, <<>>} = receive_frame(port, <<>>)

    Port.close(port)

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

    wrong_device_request =
      put_in(request, ["output_root", "device"], output_root["device"] + 1)

    wrong_device_helper = fake_web_helper(root, "wrong-device", terminal)

    assert {:error, :helper_protocol} =
             Helper.run_web(wrong_device_helper, wrong_device_request, state)

    replacement_output = Path.join(root, "replacement-output")
    moved_output = Path.join(root, "admitted-output")
    File.mkdir!(replacement_output)

    Enum.each([Web.marker(), "app.js", "app_bg.wasm"], fn path ->
      File.cp!(Path.join(output, path), Path.join(replacement_output, path))
    end)

    File.chmod!(Path.join(replacement_output, Web.marker()), 0o600)
    replacement_helper = fake_web_helper(root, "replacement-output", terminal)
    File.rename!(output, moved_output)
    File.rename!(replacement_output, output)

    try do
      assert {:error, :helper_protocol} = Helper.run_web(replacement_helper, request, state)
    after
      File.rm_rf!(output)
      File.rename!(moved_output, output)
    end

    extra_helper = fake_web_helper(root, "extra", terminal, extra: true)
    assert {:error, :post_terminal_frame} = Helper.run_web(extra_helper, request, state)

    helper_root = temp_root("web-forged-helper-executable")
    File.mkdir_p!(helper_root)
    on_exit(fn -> File.rm_rf!(helper_root) end)
    ancestor_helper = fake_web_helper(helper_root, "root-ancestor", terminal)
    moved_root = root <> "-real"
    File.rename!(root, moved_root)
    File.ln_s!(moved_root, root)

    try do
      assert {:error, :helper_protocol} = Helper.run_web(ancestor_helper, request, state)
    after
      File.rm!(root)
      File.rename!(moved_root, root)
    end

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
      "app.js" => ~S"""
      import "./modules/static.js";
      export { value } from "./modules/exported.js";
      const lazy = import("./modules/lazy.js");
      const wasm = new URL("./app_bg.wasm", import.meta.url);
      export const matcher = / from "\.\/missing.js"/;
      export const template = `from "./also-missing.js"; import("./ghost.js")`;
      export const interpolated = `${import("./modules/interpolated.js")}`;
      export const nested = `${`raw ${import("./modules/nested-template.js")}`}`;
      export const templateMatcher = `${/}/.test("}")}`;
      const objectKey = { export: { from: "./missing-key.js" } };
      const obj = { export(value) { return value; } };
      obj.export({ from: "./missing-member.js" });
      const property = obj.export;
      const importKey = { import: { from: "./missing-import-key.js" } };
      const importObj = { import(value) { return value; } };
      importObj.import({ from: "./missing-import-member.js" });
      const importProperty = importObj.import;
      const asyncImportObj = { async import(value) { return value; } };
      class Loader {
        import(value) { return value; }
        async import(value) { return value; }
        *import(value) { yield value; }
        get import() { return importProperty; }
        set import(value) { this.value = value; }
      }
      class PrivateLoader {
        #import(value) { return value; }
        run() { return this.#import(1); }
      }
      export default async function init() { return [lazy, wasm, matcher, template, interpolated, nested, templateMatcher, objectKey, property, importKey, importProperty, asyncImportObj, Loader, PrivateLoader]; }
      //# sourceMappingURL=app.js.map
      """,
      "app.js.map" => ~s({"version":3}),
      "app_bg.wasm" => wasm_module()
    })

    write_tree(public, %{
      "modules/static.js" => ~s(import "./nested.js"; export const value = 1;),
      "modules/exported.js" => "export const value = 2;",
      "modules/interpolated.js" => "export const value = 5;",
      "modules/lazy.js" => "export const value = 3;",
      "modules/nested-template.js" => "export const value = 6;",
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
      {"app.js", "modules/interpolated.js", "dynamic_import"},
      {"app.js", "modules/lazy.js", "dynamic_import"},
      {"app.js", "modules/nested-template.js", "dynamic_import"},
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

    assert {:ok, artifact_root} = Web.root(output, :read, id: output_root["id"])

    schema_mutations = [
      {"unknown root field", &Map.put(&1, "unknown", true)},
      {"contract version", &Map.put(&1, "contract_version", 2)},
      {"Rekindle semver", &Map.put(&1, "rekindle_version", "01.0.0")},
      {"application identity", &Map.put(&1, "application_id", "cafe\u0301")},
      {"non-ASCII application identity", &Map.put(&1, "application_id", "é")},
      {"target", &Map.put(&1, "target", "desktop")},
      {"artifact digest", &Map.put(&1, "artifact_id", "invalid")},
      {"build key", &put_in(&1, ["build", "build_key"], "invalid")},
      {"build profile", &put_in(&1, ["build", "profile"], "")},
      {"build profile bound", &put_in(&1, ["build", "profile"], String.duplicate("a", 129))},
      {"build package", &put_in(&1, ["build", "package"], "bad\npackage")},
      {"build Unicode package", &put_in(&1, ["build", "package"], "é")},
      {"build binary", &put_in(&1, ["build", "binary"], "cafe\u0301")},
      {"build features", &put_in(&1, ["build", "features"], ["web", "alpha"])},
      {"build Unicode feature", &put_in(&1, ["build", "features"], ["é"])},
      {"build feature aggregate",
       fn value ->
         features =
           for number <- 1..65 do
             String.duplicate("a", 124) <> String.pad_leading("#{number}", 4, "0")
           end

         put_in(value, ["build", "features"], features)
       end},
      {"build extra field", &update_in(&1["build"], fn build -> Map.put(build, "extra", 1) end)},
      {"producer kind", &put_in(&1, ["producer", "kind"], "canonical_desktop")},
      {"producer rustc", &put_in(&1, ["producer", "rustc"], "")},
      {"producer cargo", &put_in(&1, ["producer", "cargo"], "bad\ncargo")},
      {"producer target", &put_in(&1, ["producer", "rust_target"], "")},
      {"producer Unicode target", &put_in(&1, ["producer", "rust_target"], "é")},
      {"producer target bound",
       &put_in(&1, ["producer", "rust_target"], String.duplicate("a", 129))},
      {"producer wasm-bindgen", &put_in(&1, ["producer", "wasm_bindgen"], "0.02.1")},
      {"producer GPUI revision", &put_in(&1, ["producer", "gpui_revision"], "")},
      {"producer short GPUI revision",
       &put_in(&1, ["producer", "gpui_revision"], String.duplicate("b", 39))},
      {"producer uppercase GPUI revision",
       &put_in(&1, ["producer", "gpui_revision"], String.duplicate("B", 40))},
      {"producer long GPUI revision",
       &put_in(&1, ["producer", "gpui_revision"], String.duplicate("b", 65))},
      {"producer helper version", &put_in(&1, ["producer", "helper_version"], "v0.1.0")},
      {"producer helper protocol", &put_in(&1, ["producer", "helper_protocol"], 2)},
      {"producer tuple", &put_in(&1, ["producer", "compatibility_tuple_id"], "")},
      {"producer short tuple",
       &put_in(&1, ["producer", "compatibility_tuple_id"], String.duplicate("c", 63))},
      {"producer uppercase tuple",
       &put_in(&1, ["producer", "compatibility_tuple_id"], String.duplicate("C", 64))},
      {"producer extra field",
       &update_in(&1["producer"], fn producer -> Map.put(producer, "extra", 1) end)},
      {"extension backend ID",
       &Map.put(&1, "producer", %{
         "kind" => "extension",
         "backend_id" => "INVALID",
         "backend_version" => "1",
         "options_digest" => String.duplicate("c", 64)
       })},
      {"extension Unicode backend ID",
       &Map.put(&1, "producer", %{
         "kind" => "extension",
         "backend_id" => "é",
         "backend_version" => "1",
         "options_digest" => String.duplicate("c", 64)
       })},
      {"extension Unicode version",
       &Map.put(&1, "producer", %{
         "kind" => "extension",
         "backend_id" => "example.backend",
         "backend_version" => "é",
         "options_digest" => String.duplicate("c", 64)
       })},
      {"extension empty version",
       &Map.put(&1, "producer", %{
         "kind" => "extension",
         "backend_id" => "example.backend",
         "backend_version" => "",
         "options_digest" => String.duplicate("c", 64)
       })},
      {"extension bounded version",
       &Map.put(&1, "producer", %{
         "kind" => "extension",
         "backend_id" => "example.backend",
         "backend_version" => String.duplicate("a", 129),
         "options_digest" => String.duplicate("c", 64)
       })},
      {"secure-context requirement", &put_in(&1, ["host_requirements", "secure_context"], false)},
      {"WebGPU requirement", &put_in(&1, ["host_requirements", "webgpu"], false)},
      {"host-requirement extra field",
       &update_in(&1["host_requirements"], fn host -> Map.put(host, "extra", true) end)},
      {"entry path", &Map.put(&1, "entry", "../entry.js")},
      {"second bootstrap",
       fn value ->
         javascript = Enum.find(value["members"], &(&1["role"] == "javascript"))

         value
         |> update_in(["members"], fn members ->
           Enum.map(members, fn member ->
             if member["path"] == javascript["path"],
               do: %{member | "role" => "bootstrap", "cache" => "no_cache"},
               else: member
           end)
         end)
         |> with_web_artifact_id()
       end},
      {"hot-style order", &Map.put(&1, "hot_styles", ["styles/theme.css", "styles/app.css"])},
      {"member unknown field",
       &update_in(&1["members"], fn [member | rest] -> [Map.put(member, "extra", 1) | rest] end)},
      {"member non-NFC path",
       fn value ->
         update_in(value["members"], fn [member | rest] ->
           [%{member | "path" => "cafe\u0301.js"} | rest]
           |> Enum.sort_by(fn candidate -> candidate["path"] end)
         end)
       end},
      {"member path bound",
       fn value ->
         update_in(value["members"], fn [member | rest] ->
           [%{member | "path" => String.duplicate("a", 4_097)} | rest]
           |> Enum.sort_by(fn candidate -> candidate["path"] end)
         end)
       end}
    ]

    metadata_mutations =
      for member <- manifest["members"], field <- ~w[mime cache] do
        {"#{member["role"]} #{field}",
         fn value ->
           update_in(value["members"], fn members ->
             Enum.map(members, fn candidate ->
               if candidate["path"] == member["path"],
                 do: Map.put(candidate, field, "invalid"),
                 else: candidate
             end)
           end)
         end}
      end

    Enum.each(schema_mutations ++ metadata_mutations, fn {label, mutate} ->
      assert_web_manifest_rejected(helper, artifact_root, output, mutate.(manifest), label)
    end)

    case_collision =
      update_in(manifest["members"], fn members ->
        source =
          members
          |> Enum.find(&(&1["path"] == "styles/image.png"))

        collisions =
          for path <- ["STRASSE.txt", "Straße.txt"] do
            %{source | "path" => path, "mime" => "text/plain; charset=utf-8"}
          end

        Enum.sort_by(collisions ++ members, & &1["path"])
      end)
      |> with_web_artifact_id()

    assert_web_manifest_rejected(
      helper,
      artifact_root,
      output,
      case_collision,
      "case-fold collision"
    )

    empty_features_manifest = put_in(manifest, ["build", "features"], [])

    assert_web_manifest_verified(
      helper,
      artifact_root,
      output,
      empty_features_manifest,
      "empty feature list"
    )

    extension_manifest =
      manifest
      |> Map.put("producer", %{
        "kind" => "extension",
        "backend_id" => "example.backend",
        "backend_version" => "1",
        "options_digest" => String.duplicate("c", 64)
      })

    assert_web_manifest_verified(
      helper,
      artifact_root,
      output,
      extension_manifest,
      "extension Producer"
    )

    File.write!(
      Path.join(output, "rekindle-web-manifest-v1.json"),
      CanonicalValue.encode!(manifest)
    )

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

  test "web-v1 emits the normative MIME and cache table and rejects role-extension aliases", %{
    helper: helper
  } do
    root = temp_root("web-metadata")
    bindgen = Path.join(root, "bindgen")
    public = Path.join(root, "public")
    output = Path.join(root, "output")
    Enum.each([bindgen, public, output], &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf!(root) end)

    write_tree(bindgen, %{
      "app.js" => "export default async function init() {}\n//# sourceMappingURL=app.js.map",
      "app.js.map" => ~s({"version":3}),
      "app_bg.wasm" => wasm_module()
    })

    asset_mimes = %{
      "assets/a.png" => "image/png",
      "assets/a.jpg" => "image/jpeg",
      "assets/a.jpeg" => "image/jpeg",
      "assets/a.gif" => "image/gif",
      "assets/a.webp" => "image/webp",
      "assets/a.avif" => "image/avif",
      "assets/a.svg" => "image/svg+xml",
      "assets/a.ico" => "image/x-icon",
      "assets/a.woff" => "font/woff",
      "assets/a.woff2" => "font/woff2",
      "assets/a.ttf" => "font/ttf",
      "assets/a.otf" => "font/otf",
      "assets/a.txt" => "text/plain; charset=utf-8",
      "assets/a.json" => "application/json; charset=utf-8",
      "assets/a.bin" => "application/octet-stream",
      "assets/case.PNG" => "image/png"
    }

    public_files =
      asset_mimes
      |> Map.keys()
      |> Map.new(&{&1, "asset"})
      |> Map.put("styles/app.css", "body {}")

    write_tree(public, public_files)

    assert {:ok, bindgen_root} = Web.root(bindgen, :read, id: id(300))
    assert {:ok, public_root} = Web.root(public, :read, id: id(301))
    assert {:ok, output_root} = Web.prepare_output_root(output, id: id(302))

    assert {:ok, request, state} =
             package_operation(
               bindgen_root,
               web_files(bindgen_root, Map.keys(read_tree(bindgen))),
               public_root,
               web_files(public_root, Map.keys(read_tree(public))),
               output_root,
               hot_styles: ["styles/app.css"]
             )

    assert {:ok, %{"type" => "operation_ok"}, []} = Helper.run_web(helper, request, state)

    members =
      output
      |> Path.join("rekindle-web-manifest-v1.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("members")
      |> Map.new(&{&1["path"], &1})

    assert members["entry.js"] |> Map.take(~w[role mime cache]) == %{
             "role" => "bootstrap",
             "mime" => "text/javascript; charset=utf-8",
             "cache" => "no_cache"
           }

    assert members["app.js"] |> Map.take(~w[role mime cache]) == %{
             "role" => "javascript",
             "mime" => "text/javascript; charset=utf-8",
             "cache" => "immutable"
           }

    assert members["app_bg.wasm"] |> Map.take(~w[role mime cache]) == %{
             "role" => "wasm",
             "mime" => "application/wasm",
             "cache" => "immutable"
           }

    assert members["app.js.map"] |> Map.take(~w[role mime cache]) == %{
             "role" => "source_map",
             "mime" => "application/json; charset=utf-8",
             "cache" => "immutable"
           }

    assert members["styles/app.css"] |> Map.take(~w[role mime cache]) == %{
             "role" => "css",
             "mime" => "text/css; charset=utf-8",
             "cache" => "immutable"
           }

    Enum.each(asset_mimes, fn {path, mime} ->
      assert members[path]["role"] == "asset"
      assert members[path]["mime"] == mime
      assert members[path]["cache"] == "immutable"
    end)

    for forbidden <- ["bad.JS", "bad.WASM", "bad.CSS", "bad.MAP"] do
      rejected_output = Path.join(root, "rejected-#{forbidden}")
      File.mkdir_p!(rejected_output)
      File.write!(Path.join(public, forbidden), "forbidden")
      assert {:ok, rejected_root} = Web.prepare_output_root(rejected_output, id: id(400))

      assert {:ok, rejected_request, rejected_state} =
               package_operation(
                 bindgen_root,
                 web_files(bindgen_root, Map.keys(read_tree(bindgen))),
                 public_root,
                 web_files(public_root, Map.keys(read_tree(public))),
                 rejected_root
               )

      assert {:ok, %{"type" => "operation_error", "code" => "unsupported_import"}, []} =
               Helper.run_web(helper, rejected_request, rejected_state)

      File.rm!(Path.join(public, forbidden))
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

    assert {:ok, artifact_root} = Web.root(package_output, :read, id: package_root["id"])
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

    member_file =
      package_output
      |> Path.join("members/**/*")
      |> Path.wildcard()
      |> Enum.find(&File.regular?/1)

    replace_with_symlink = fn path, backup ->
      File.rename!(path, backup)
      File.ln_s!(backup, path)

      fn ->
        File.rm!(path)
        File.rename!(backup, path)
      end
    end

    mutations = [
      {"root extra file",
       fn ->
         path = Path.join(package_output, "undeclared.txt")
         File.write!(path, "extra")
         fn -> File.rm!(path) end
       end},
      {"changed attempt marker",
       fn ->
         path = Path.join(package_output, Web.marker())
         original = File.read!(path)
         File.write!(path, ~s({"root_id":"ffffffffffffffffffffffffffffffff","v":1}))

         fn ->
           File.write!(path, original)
           File.chmod!(path, 0o600)
         end
       end},
      {"nested extra file",
       fn ->
         path = Path.join(package_output, "members/undeclared.js")
         File.write!(path, "extra")
         fn -> File.rm!(path) end
       end},
      {"unexpected directory",
       fn ->
         path = Path.join(package_output, "unexpected-directory")
         File.mkdir!(path)
         fn -> File.rmdir!(path) end
       end},
      {"symlink to file",
       fn ->
         path = Path.join(package_output, "linked-file")
         File.ln_s!(member_file, path)
         fn -> File.rm!(path) end
       end},
      {"symlink to directory",
       fn ->
         path = Path.join(package_output, "linked-directory")
         File.ln_s!(Path.join(package_output, "members"), path)
         fn -> File.rm!(path) end
       end},
      {"declared member symlink",
       fn ->
         replace_with_symlink.(member_file, Path.join(root, "member-backup"))
       end},
      {"declared member ancestor symlink",
       fn ->
         directory = Path.join(package_output, "members")
         replace_with_symlink.(directory, Path.join(root, "member-directory-backup"))
       end},
      {"manifest symlink",
       fn ->
         path = Path.join(package_output, "rekindle-web-manifest-v1.json")
         replace_with_symlink.(path, Path.join(root, "manifest-backup"))
       end},
      {"marker symlink",
       fn ->
         path = Path.join(package_output, Web.marker())
         replace_with_symlink.(path, Path.join(root, "marker-backup"))
       end},
      {"FIFO",
       fn ->
         path = Path.join(package_output, "unexpected-fifo")
         {_, 0} = System.cmd("mkfifo", [path], stderr_to_stdout: true)
         fn -> File.rm!(path) end
       end},
      {"Unix socket",
       fn ->
         path = Path.join(package_output, "unexpected-socket")

         {:ok, socket} =
           :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, path}])

         fn ->
           :ok = :gen_tcp.close(socket)
           File.rm!(path)
         end
       end},
      {"root ancestor symlink",
       fn ->
         moved_root = root <> "-real"
         File.rename!(root, moved_root)
         File.ln_s!(moved_root, root)

         fn ->
           File.rm!(root)
           File.rename!(moved_root, root)
         end
       end}
    ]

    for {label, mutate} <- mutations do
      cleanup = mutate.()

      try do
        assert {:error, :manifest_changed} = Web.revalidate_manifest(artifact_root, verified),
               label

        assert {:ok, %{"type" => "operation_error", "code" => code}, []} =
                 Helper.run_web(helper, request, state),
               label

        assert code in ["input_changed", "asset_escape"], label
      after
        cleanup.()
      end

      assert Web.revalidate_manifest(artifact_root, verified) == :ok, "#{label} cleanup"
    end

    assert {:ok, %{"type" => "operation_ok", "op" => "verify_web"}, []} =
             Helper.run_web(helper, request, state)

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
        compatibility_tuple_id: String.duplicate("c", 64)
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

  defp with_web_manifest_digest(manifest),
    do: Map.put(manifest, "manifest_digest", web_manifest_digest(manifest))

  defp with_web_artifact_id(manifest) do
    identity = %{
      "v" => 1,
      "build_key" => manifest["build"]["build_key"],
      "members" => Enum.map(manifest["members"], &Map.take(&1, ~w[path role sha256 size]))
    }

    artifact_id =
      :crypto.hash(:sha256, ["rekindle-web-artifact-v1\0", CanonicalValue.encode!(identity)])
      |> Base.encode16(case: :lower)

    Map.put(manifest, "artifact_id", artifact_id)
  end

  defp assert_web_manifest_verified(helper, root, output, manifest, label) do
    manifest = with_web_manifest_digest(manifest)
    path = Path.join(output, "rekindle-web-manifest-v1.json")
    File.write!(path, CanonicalValue.encode!(manifest))

    assert :ok ==
             Web.revalidate_manifest(root, %{
               "artifact_id" => manifest["artifact_id"],
               "manifest_digest" => manifest["manifest_digest"]
             }),
           label

    assert {:ok, descriptor} = Web.file(root, "rekindle-web-manifest-v1.json"), label

    assert {:ok, request, state} =
             Web.operation(
               "verify_web",
               %{
                 artifact_root: root,
                 manifest: descriptor,
                 expected_manifest_digest: manifest["manifest_digest"],
                 limits: limits()
               },
               request_id: @request
             ),
           label

    assert {:ok, %{"type" => "operation_ok", "op" => "verify_web"}, []} =
             Helper.run_web(helper, request, state),
           label
  end

  defp assert_web_manifest_rejected(helper, root, output, manifest, label) do
    manifest = with_web_manifest_digest(manifest)
    path = Path.join(output, "rekindle-web-manifest-v1.json")
    File.write!(path, CanonicalValue.encode!(manifest))
    assert {:ok, descriptor} = Web.file(root, "rekindle-web-manifest-v1.json"), label

    assert {:ok, request, state} =
             Web.operation(
               "verify_web",
               %{
                 artifact_root: root,
                 manifest: descriptor,
                 expected_manifest_digest: manifest["manifest_digest"],
                 limits: limits()
               },
               request_id: @request
             ),
           label

    assert {:ok, %{"type" => "operation_error"}, []} = Helper.run_web(helper, request, state),
           label

    assert {:error, :manifest_changed} =
             Web.revalidate_manifest(root, %{
               "artifact_id" => manifest["artifact_id"],
               "manifest_digest" => manifest["manifest_digest"]
             }),
           label
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

  defp assert_hello_error(helper, hello, code, actual, host) do
    port = open_helper(helper, "web-v1")
    nonce = hello["session_nonce"]
    assert {:ok, encoded} = Frame.encode(hello)
    assert Port.command(port, encoded)

    assert {:ok,
            %{
              "v" => 1,
              "type" => "hello_error",
              "request_id" => @request,
              "payload_len" => 0,
              "session_nonce" => ^nonce,
              "mode" => "web-v1",
              "code" => ^code,
              "expected" => expected,
              "actual" => ^actual,
              "host" => ^host
            }, <<>>} = receive_frame(port, <<>>)

    assert expected == hello["expected"]
    assert_receive {^port, {:exit_status, 2}}, 1_000
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

  defp padded_script(body, size) do
    prefix = "#!/bin/sh\n" <> body <> "#"
    true = byte_size(prefix) <= size
    prefix <> String.duplicate("x", size - byte_size(prefix))
  end

  defp temp_root(label) do
    Path.join(
      System.tmp_dir!(),
      "rekindle-helper-#{label}-#{System.unique_integer([:positive])}"
    )
  end
end
