defmodule Rekindle.Toolchain.BootstrapTest do
  use ExUnit.Case, async: false

  alias Rekindle.Toolchain.Web

  @moduletag timeout: 30_000
  @artifact String.duplicate("a", 64)
  @generation String.duplicate("b", 32)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "rekindle-bootstrap-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.write!(Path.join(root, "package.json"), ~s({"type":"module"}\n))
    File.write!(Path.join(root, "app.wasm"), <<>>)
    File.write!(Path.join(root, "style.css"), "body {}\n")

    File.write!(
      Path.join(root, "entry.js"),
      Web.render_bootstrap("app.js", "app.wasm", ["style.css"])
    )

    File.write!(Path.join(root, "app.js"), application_module())
    File.write!(Path.join(root, "runner.js"), runner_module())
    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root}
  end

  test "admits the exact context and resolves only after Rust readiness", %{root: root} do
    assert %{
             "ok" => true,
             "result" => %{
               "v" => 1,
               "generation_id" => @generation,
               "window_count" => 2
             },
             "bridge_present" => true,
             "bridge_keys" => [
               "artifact_id",
               "fail",
               "generation_id",
               "ready",
               "register_handoff",
               "take_handoff",
               "v"
             ]
           } = run_scenario(root, "success")

    assert %{
             "ok" => true,
             "result" => %{"v" => 1, "generation_id" => nil, "window_count" => 2}
           } = run_scenario(root, "production")
  end

  test "rejects closed-context and top-level page violations before importing Wasm", %{root: root} do
    for scenario <- [
          "context_missing",
          "context_extra",
          "generation_invalid",
          "artifact_invalid",
          "handoff_invalid",
          "no_body",
          "no_marker",
          "two_markers",
          "invalid_marker",
          "iframe"
        ] do
      assert %{
               "ok" => false,
               "error_code" => "incompatible",
               "bridge_present" => false,
               "initializer_calls" => 0
             } = run_scenario(root, scenario)
    end
  end

  test "removes its bridge after initializer, readiness, window, stylesheet, and timeout failures",
       %{
         root: root
       } do
    for {scenario, code} <- [
          {"initializer_failure", nil},
          {"invalid_ready", "invalid_payload"},
          {"duplicate_terminal", "invalid_state"},
          {"window_failure", "window_open"},
          {"stylesheet_failure", "application"},
          {"timeout", "deadline"}
        ] do
      assert %{
               "ok" => false,
               "error_code" => ^code,
               "bridge_present" => false
             } = run_scenario(root, scenario)
    end
  end

  test "failed old-generation cleanup cannot remove a newer bridge", %{root: root} do
    assert %{
             "ok" => false,
             "bridge_present" => true,
             "newer_bridge" => true
           } = run_scenario(root, "newer_bridge")
  end

  defp run_scenario(root, scenario) do
    node = System.find_executable("node") || flunk("node is unavailable")

    {output, status} =
      System.cmd(node, ["runner.js"],
        cd: root,
        env: [{"SCENARIO", scenario}, {"ARTIFACT_ID", @artifact}, {"GENERATION_ID", @generation}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert {:ok, result} = Jason.decode(String.trim(output))
    result
  end

  defp application_module do
    """
    export default async function initialize(wasm) {
      globalThis.__INITIALIZER_CALLS__ += 1;
      if (!(wasm instanceof URL) || !wasm.pathname.endsWith("/app.wasm")) {
        throw new Error("invalid Wasm URL");
      }
      const bridge = globalThis.__REKINDLE_RUNTIME_V1__;
      switch (process.env.SCENARIO) {
        case "initializer_failure":
          throw new Error("initializer failed");
        case "invalid_ready":
          bridge.ready({v: 1, window_count: -1});
          return;
        case "duplicate_terminal":
          bridge.ready({v: 1, window_count: 1});
          bridge.ready({v: 1, window_count: 1});
          return;
        case "window_failure":
          bridge.fail({v: 1, code: "window_open", message: "window failed"});
          return;
        case "timeout":
          return await new Promise(() => {});
        case "newer_bridge":
          globalThis.__REKINDLE_RUNTIME_V1__ = Object.freeze({v: 1, newer: true});
          throw new Error("candidate failed after replacement");
        default: {
          const restored = await bridge.take_handoff({
            v: 1,
            application_id: "sample_app",
            schema_version: 1,
            destination_artifact_id: bridge.artifact_id,
          });
          const registered = bridge.register_handoff({
            v: 1,
            application_id: "sample_app",
            schema_version: 1,
            max_bytes: 0,
            snapshot: async () => null,
          });
          if (restored !== null || registered.v !== 1 || registered.status !== "disabled") {
            throw new Error("invalid no-op handoff bridge");
          }
          bridge.ready({v: 1, window_count: 2});
        }
      }
    }
    """
  end

  defp runner_module do
    """
    const scenario = process.env.SCENARIO;
    globalThis.__INITIALIZER_CALLS__ = 0;
    globalThis.window = globalThis;
    globalThis.top = scenario === "iframe" ? {} : globalThis;
    const marker = {
      tagName: scenario === "invalid_marker" ? "DIV" : "SCRIPT",
      getAttribute(name) { return name === "type" ? "module" : null; },
    };
    const markerCount = scenario === "no_marker" ? 0 : scenario === "two_markers" ? 2 : 1;
    globalThis.document = {
      body: scenario === "no_body" ? null : {},
      head: {
        appendChild(link) {
          queueMicrotask(() => scenario === "stylesheet_failure" ? link.onerror() : link.onload());
        },
      },
      createElement() { return {remove() {}}; },
      querySelectorAll() { return Array.from({length: markerCount}, () => marker); },
    };
    if (scenario === "timeout") {
      const schedule = globalThis.setTimeout;
      globalThis.setTimeout = (callback, _delay) => schedule(callback, 0);
    }
    let context = {
      v: 1,
      generation_id: process.env.GENERATION_ID,
      artifact_id: process.env.ARTIFACT_ID,
      handoff: null,
    };
    if (scenario === "production") context.generation_id = null;
    if (scenario === "context_missing") delete context.handoff;
    if (scenario === "context_extra") context.extra = true;
    if (scenario === "generation_invalid") context.generation_id = "ABC";
    if (scenario === "artifact_invalid") context.artifact_id = "bad";
    if (scenario === "handoff_invalid") context.handoff = {};

    const {start} = await import("./entry.js");
    try {
      const result = await start(context);
      const bridge = globalThis.__REKINDLE_RUNTIME_V1__;
      console.log(JSON.stringify({
        ok: true,
        result,
        bridge_present: Boolean(bridge),
        bridge_keys: Object.keys(bridge).sort(),
        initializer_calls: globalThis.__INITIALIZER_CALLS__,
      }));
    } catch (error) {
      const bridge = globalThis.__REKINDLE_RUNTIME_V1__;
      console.log(JSON.stringify({
        ok: false,
        error_code: error && Object.hasOwn(error, "code") ? error.code : null,
        error_message: error instanceof Error ? error.message : String(error),
        bridge_present: Boolean(bridge),
        newer_bridge: Boolean(bridge && bridge.newer),
        initializer_calls: globalThis.__INITIALIZER_CALLS__,
      }));
    }
    """
  end
end
