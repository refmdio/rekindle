defmodule Rekindle.Toolchain.WebTest do
  use ExUnit.Case, async: true

  alias Rekindle.Toolchain.Web

  @request "0123456789abcdef0123456789abcdef"

  setup do
    base = Path.join(System.tmp_dir!(), "rekindle-web-#{System.unique_integer([:positive])}")
    input = Path.join(base, "input")
    output = Path.join(base, "output")
    File.mkdir_p!(input)
    File.mkdir_p!(output)
    File.write!(Path.join(input, "app.wasm"), "wasm")
    on_exit(fn -> File.rm_rf!(base) end)
    %{input: input, output: output}
  end

  test "constructs exact Root, File, Limits and all three operation bodies", roots do
    assert {:ok, input_root} =
             Web.root(roots.input, :read, id: "11111111111111111111111111111111")

    assert {:ok, output_root} =
             Web.root(roots.output, :write_empty, id: "22222222222222222222222222222222")

    assert {:ok, wasm} = Web.file(input_root, "app.wasm")

    assert {:ok, limits} =
             Web.limits(
               max_files: 10,
               max_input_bytes: 100,
               max_output_bytes: 200,
               deadline_ms: 1_000
             )

    assert {:ok, bindgen, %Web{op: "bindgen_web"}} =
             Web.operation(
               "bindgen_web",
               %{
                 input_wasm: wasm,
                 output_root: output_root,
                 output_stem: "app",
                 debug: false,
                 source_maps: :none,
                 expected_wasm_bindgen: "0.2.121",
                 limits: limits
               }, request_id: @request)

    assert Map.keys(bindgen) |> Enum.sort() ==
             ~w[v type request_id payload_len op input_wasm output_root output_stem debug source_maps expected_wasm_bindgen limits]
             |> Enum.sort()

    package_body = %{
      bindgen_root: %{input_root | "id" => "33333333333333333333333333333333"},
      bindgen_files: [%{wasm | "root_id" => "33333333333333333333333333333333"}],
      public_root: nil,
      public_files: [],
      bootstrap_template: %{id: "v1", sha256: String.duplicate("a", 64)},
      output_root: output_root,
      manifest_base: %{rekindle_version: "0.1.0"},
      limits: limits
    }

    assert {:ok, _, %Web{op: "package_web"}} =
             Web.operation("package_web", package_body, request_id: @request)

    verify = %{
      artifact_root: input_root,
      manifest: wasm,
      expected_manifest_digest: String.duplicate("b", 64),
      limits: limits
    }

    assert {:ok, _, %Web{op: "verify_web"}} =
             Web.operation("verify_web", verify, request_id: @request)
  end

  test "requires write-empty roots and rejects changed, escaping, symlink, and undeclared output",
       roots do
    File.write!(Path.join(roots.output, Web.marker()), "attempt")

    assert {:ok, output_root} =
             Web.root(roots.output, :write_empty, id: "22222222222222222222222222222222")

    File.write!(Path.join(roots.output, "app.js"), "one")
    assert {:ok, descriptor} = Web.file(output_root, "app.js")
    assert :ok = Web.revalidate_files(output_root, [descriptor])

    File.write!(Path.join(roots.output, "app.js"), "changed")
    assert {:error, :output_changed} = Web.revalidate_files(output_root, [descriptor])

    File.write!(Path.join(roots.output, "extra.js"), "extra")
    assert {:ok, changed} = Web.file(output_root, "app.js")
    assert {:error, :output_changed} = Web.revalidate_files(output_root, [changed])
    assert {:error, :invalid_file} = Web.file(output_root, "../escape")

    symlink = Path.join(roots.output, "link")
    File.ln_s!(Path.join(roots.output, "app.js"), symlink)
    assert {:error, :invalid_file} = Web.file(output_root, "link")
  end

  test "enforces ordered progress, terminal union, and post-terminal rejection" do
    state = %Web{request_id: @request, op: "verify_web"}

    diagnostic = %{
      "severity" => "info",
      "code" => "verify",
      "message" => "checking",
      "path" => nil,
      "line" => nil
    }

    progress = %{
      "v" => 1,
      "type" => "operation_progress",
      "request_id" => @request,
      "payload_len" => 0,
      "sequence" => 0,
      "diagnostic" => diagnostic
    }

    assert {:ok, state, ^diagnostic} = Web.accept(state, progress)
    assert {:error, :invalid_progress} = Web.accept(state, %{progress | "sequence" => 0})

    terminal = %{
      "v" => 1,
      "type" => "operation_ok",
      "request_id" => @request,
      "payload_len" => 0,
      "op" => "verify_web",
      "artifact_id" => String.duplicate("a", 64),
      "manifest_digest" => String.duplicate("b", 64),
      "members_verified" => 3,
      "total_bytes" => 10
    }

    assert {:terminal, ^terminal, state} = Web.accept(state, terminal)
    assert {:error, :post_terminal_frame} = Web.accept(state, terminal)
  end

  test "admits only closed helper error codes and matching operations" do
    state = %Web{request_id: @request, op: "bindgen_web"}

    error = %{
      "v" => 1,
      "type" => "operation_error",
      "request_id" => @request,
      "payload_len" => 0,
      "op" => "bindgen_web",
      "code" => "invalid_wasm",
      "message" => "not wasm",
      "diagnostics" => []
    }

    assert {:terminal, ^error, _} = Web.accept(state, error)
    assert {:error, :invalid_operation_error} = Web.accept(state, %{error | "code" => "unknown"})
  end
end
