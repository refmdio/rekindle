defmodule Rekindle.Toolchain.WebTest do
  use ExUnit.Case, async: true

  alias Rekindle.Toolchain.Web
  alias Rekindle.CanonicalValue

  @request "0123456789abcdef0123456789abcdef"
  @max_safe_integer 9_007_199_254_740_991

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
             Web.prepare_output_root(roots.output,
               id: "22222222222222222222222222222222"
             )

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
                 input_root: input_root,
                 input_wasm: wasm,
                 output_root: output_root,
                 output_stem: "app",
                 debug: false,
                 source_maps: :none,
                 expected_wasm_bindgen: "0.2.121",
                 limits: limits
               },
               request_id: @request
             )

    assert Map.keys(bindgen) |> Enum.sort() ==
             ~w[v type request_id payload_len op input_root input_wasm output_root output_stem debug source_maps expected_wasm_bindgen limits]
             |> Enum.sort()

    package_body = %{
      bindgen_root: %{input_root | "id" => "33333333333333333333333333333333"},
      bindgen_files: [%{wasm | "root_id" => "33333333333333333333333333333333"}],
      public_root: nil,
      public_files: [],
      bootstrap_template: %{id: "v1", sha256: String.duplicate("a", 64)},
      output_root: output_root,
      manifest_base: manifest_base(),
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

  test "admits only positive safe integers for every Limits field", roots do
    fields = [:max_files, :max_input_bytes, :max_output_bytes, :deadline_ms]
    defaults = [max_files: 1, max_input_bytes: 1, max_output_bytes: 1, deadline_ms: 1]

    for field <- fields do
      assert {:ok, limits} = Web.limits(Keyword.put(defaults, field, @max_safe_integer))
      assert is_binary(CanonicalValue.encode!(limits))

      for invalid <- [0, -1, 1.5, @max_safe_integer + 1] do
        assert {:error, :invalid_limits} = Web.limits(Keyword.put(defaults, field, invalid))
      end
    end

    assert {:ok, input_root} = Web.root(roots.input, :read)
    assert {:ok, wasm} = Web.file(input_root, "app.wasm")
    assert {:ok, output_root} = Web.prepare_output_root(roots.output)
    {:ok, limits} = Web.limits(defaults)

    body = %{
      input_root: input_root,
      input_wasm: wasm,
      output_root: output_root,
      output_stem: "app",
      debug: false,
      source_maps: :none,
      expected_wasm_bindgen: "0.2.121",
      limits: limits
    }

    for field <- Enum.map(fields, &Atom.to_string/1) do
      safe = put_in(body, [:limits, field], @max_safe_integer)
      assert {:ok, request, _state} = Web.operation("bindgen_web", safe)
      assert is_binary(CanonicalValue.encode!(request))

      overflow = put_in(body, [:limits, field], @max_safe_integer + 1)
      assert {:error, :invalid_operation} = Web.operation("bindgen_web", overflow)
    end
  end

  test "encodes the closed bindgen request byte-exactly" do
    digest = String.duplicate("a", 64)

    assert {:ok, request, _state} =
             Web.operation(
               "bindgen_web",
               %{
                 input_root: %{
                   id: "11111111111111111111111111111111",
                   path: "/input",
                   mode: "read",
                   device: 7
                 },
                 input_wasm: %{
                   root_id: "11111111111111111111111111111111",
                   path: "app.wasm",
                   sha256: digest,
                   size: 8,
                   mode: "data"
                 },
                 output_root: %{
                   id: "22222222222222222222222222222222",
                   path: "/output",
                   mode: "write_empty",
                   device: 7
                 },
                 output_stem: "app",
                 debug: true,
                 source_maps: "external",
                 expected_wasm_bindgen: "0.2.121",
                 limits: %{
                   max_files: 10,
                   max_input_bytes: 100,
                   max_output_bytes: 200,
                   deadline_ms: 1_000
                 }
               },
               request_id: @request
             )

    assert CanonicalValue.encode!(request) ==
             ~s({"debug":true,"expected_wasm_bindgen":"0.2.121","input_root":{"device":7,"id":"11111111111111111111111111111111","mode":"read","path":"/input"},"input_wasm":{"mode":"data","path":"app.wasm","root_id":"11111111111111111111111111111111","sha256":"#{digest}","size":8},"limits":{"deadline_ms":1000,"max_files":10,"max_input_bytes":100,"max_output_bytes":200},"op":"bindgen_web","output_root":{"device":7,"id":"22222222222222222222222222222222","mode":"write_empty","path":"/output"},"output_stem":"app","payload_len":0,"request_id":"#{@request}","source_maps":"external","type":"operation","v":1})
  end

  test "admits only the exact canonical Web manifest base before helper execution", roots do
    assert {:ok, input_root} = Web.root(roots.input, :read, id: String.duplicate("1", 32))
    assert {:ok, wasm} = Web.file(input_root, "app.wasm")

    assert {:ok, output_root} =
             Web.prepare_output_root(roots.output, id: String.duplicate("2", 32))

    assert {:ok, limits} =
             Web.limits(
               max_files: 10,
               max_input_bytes: 100,
               max_output_bytes: 200,
               deadline_ms: 1_000
             )

    body = %{
      bindgen_root: input_root,
      bindgen_files: [wasm],
      public_root: nil,
      public_files: [],
      bootstrap_template: Web.bootstrap_template(),
      output_root: output_root,
      manifest_base: manifest_base(),
      limits: limits
    }

    assert {:ok, _, %Web{op: "package_web"}} = Web.operation("package_web", body)

    assert {:ok, _, %Web{op: "package_web"}} =
             Web.operation(
               "package_web",
               put_in(body, [:manifest_base, :build, :features], [])
             )

    too_many_features =
      for number <- 1..129, do: "f" <> String.pad_leading("#{number}", 3, "0")

    oversized_features =
      for number <- 1..65 do
        String.duplicate("a", 124) <> String.pad_leading("#{number}", 4, "0")
      end

    invalid_bases = [
      Map.put(manifest_base(), :unknown, true),
      Map.put(manifest_base(), :rekindle_version, "01.0.0"),
      Map.put(manifest_base(), :application_id, "bad\napp"),
      Map.put(manifest_base(), :application_id, "é"),
      Map.put(manifest_base(), :application_id, "Uppercase"),
      Map.put(manifest_base(), :target, "desktop"),
      put_in(manifest_base(), [:build, :build_key], "invalid"),
      put_in(manifest_base(), [:build, :package], "é"),
      put_in(manifest_base(), [:build, :profile], String.duplicate("a", 129)),
      put_in(manifest_base(), [:build, :binary], "bad\nbinary"),
      put_in(manifest_base(), [:build, :features], ["web", "alpha"]),
      put_in(manifest_base(), [:build, :features], ["é"]),
      put_in(manifest_base(), [:build, :features], too_many_features),
      put_in(manifest_base(), [:build, :features], oversized_features),
      update_in(manifest_base()[:build], &Map.put(&1, :extra, true)),
      put_in(manifest_base(), [:producer, :kind], "extension"),
      put_in(manifest_base(), [:producer, :rust_target], "é"),
      put_in(manifest_base(), [:producer, :rust_target], String.duplicate("a", 129)),
      put_in(manifest_base(), [:producer, :wasm_bindgen], "0.02.1"),
      put_in(manifest_base(), [:producer, :gpui_revision], String.duplicate("b", 39)),
      put_in(manifest_base(), [:producer, :gpui_revision], String.duplicate("B", 40)),
      put_in(manifest_base(), [:producer, :gpui_revision], String.duplicate("b", 65)),
      put_in(manifest_base(), [:producer, :helper_protocol], 2),
      put_in(manifest_base(), [:producer, :compatibility_tuple_id], String.duplicate("c", 63)),
      put_in(manifest_base(), [:producer, :compatibility_tuple_id], String.duplicate("C", 64)),
      update_in(manifest_base()[:producer], &Map.put(&1, :extra, true)),
      put_in(manifest_base(), [:host_requirements, :secure_context], false),
      update_in(manifest_base()[:host_requirements], &Map.put(&1, :extra, true)),
      Map.put(manifest_base(), :hot_styles, ["z.css", "a.css"]),
      Map.put(manifest_base(), :hot_styles, ["cafe\u0301.css"]),
      Map.put(manifest_base(), :hot_styles, [String.duplicate("a", 4_097)])
    ]

    Enum.each(invalid_bases, fn base ->
      assert {:error, :invalid_operation} =
               Web.operation("package_web", %{body | manifest_base: base})
    end)
  end

  test "rejects missing or mismatched Root authority for input Files", roots do
    assert {:ok, input_root} = Web.root(roots.input, :read, id: String.duplicate("1", 32))
    assert {:ok, wasm} = Web.file(input_root, "app.wasm")

    assert {:ok, output_root} =
             Web.prepare_output_root(roots.output, id: String.duplicate("2", 32))

    assert {:ok, limits} =
             Web.limits(
               max_files: 10,
               max_input_bytes: 100,
               max_output_bytes: 200,
               deadline_ms: 1_000
             )

    bindgen = %{
      input_root: input_root,
      input_wasm: %{wasm | "root_id" => String.duplicate("3", 32)},
      output_root: output_root,
      output_stem: "app",
      debug: false,
      source_maps: :none,
      expected_wasm_bindgen: "0.2.121",
      limits: limits
    }

    assert {:error, :invalid_operation} = Web.operation("bindgen_web", bindgen)

    package = %{
      bindgen_root: input_root,
      bindgen_files: [%{wasm | "root_id" => String.duplicate("3", 32)}],
      public_root: nil,
      public_files: [],
      bootstrap_template: Web.bootstrap_template(),
      output_root: output_root,
      manifest_base: %{},
      limits: limits
    }

    assert {:error, :invalid_operation} = Web.operation("package_web", package)

    verify = %{
      artifact_root: input_root,
      manifest: %{wasm | "root_id" => String.duplicate("3", 32)},
      expected_manifest_digest: String.duplicate("b", 64),
      limits: limits
    }

    assert {:error, :invalid_operation} = Web.operation("verify_web", verify)
  end

  test "requires write-empty roots and rejects changed, escaping, symlink, and undeclared output",
       roots do
    assert {:ok, output_root} =
             Web.prepare_output_root(roots.output,
               id: "22222222222222222222222222222222"
             )

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

  test "qualifies every root and file component and revalidates root authority", roots do
    base = Path.dirname(roots.input)
    aliased_base = base <> "-alias"
    linked_input = Path.join(base, "linked-input")
    on_exit(fn -> File.rm(aliased_base) end)
    File.ln_s!(base, aliased_base)
    File.ln_s!(roots.input, linked_input)

    assert {:error, :invalid_root} =
             Web.root(Path.join(aliased_base, "input"), :read,
               id: "11111111111111111111111111111111"
             )

    assert {:error, :invalid_root} =
             Web.prepare_output_root(Path.join(aliased_base, "output"),
               id: "22222222222222222222222222222222"
             )

    assert {:error, :invalid_root} =
             Web.root(linked_input, :read, id: "33333333333333333333333333333333")

    File.rm!(aliased_base)
    File.rm!(linked_input)

    assert {:ok, input_root} =
             Web.root(roots.input, :read, id: "44444444444444444444444444444444")

    assert {:error, :invalid_file} =
             Web.file(%{input_root | "device" => input_root["device"] + 1}, "app.wasm")

    replacement_input = Path.join(base, "replacement-input")
    moved_input = Path.join(base, "admitted-input")
    File.mkdir!(replacement_input)
    File.write!(Path.join(replacement_input, "app.wasm"), "wasm")
    File.rename!(roots.input, moved_input)
    File.rename!(replacement_input, roots.input)

    try do
      assert {:error, :invalid_file} = Web.file(input_root, "app.wasm")
    after
      File.rm_rf!(roots.input)
      File.rename!(moved_input, roots.input)
    end

    nested = Path.join(roots.input, "nested")
    moved_nested = Path.join(roots.input, "nested-real")
    File.mkdir!(nested)
    File.write!(Path.join(nested, "member.js"), "member")
    File.rename!(nested, moved_nested)
    File.ln_s!(moved_nested, nested)

    try do
      assert {:error, :invalid_file} = Web.file(input_root, "nested/member.js")
    after
      File.rm!(nested)
      File.rename!(moved_nested, nested)
    end

    authority = Path.join(base, "authority")
    moved_authority = Path.join(base, "authority-real")
    authority_input = Path.join(authority, "input")
    File.mkdir_p!(authority_input)
    File.write!(Path.join(authority_input, "member.js"), "member")

    assert {:ok, authority_root} =
             Web.root(authority_input, :read, id: "55555555555555555555555555555555")

    File.rename!(authority, moved_authority)
    File.ln_s!(moved_authority, authority)

    try do
      assert {:error, :invalid_file} = Web.file(authority_root, "member.js")
    after
      File.rm!(authority)
      File.rename!(moved_authority, authority)
    end

    assert {:ok, output_root} =
             Web.prepare_output_root(roots.output,
               id: "66666666666666666666666666666666"
             )

    File.write!(Path.join(roots.output, "app.js"), "app")
    assert {:ok, descriptor} = Web.file(output_root, "app.js")

    assert {:error, :output_changed} =
             Web.revalidate_files(
               %{output_root | "device" => output_root["device"] + 1},
               [descriptor]
             )

    replacement_output = Path.join(base, "replacement-output")
    moved_output = Path.join(base, "admitted-output")
    File.mkdir!(replacement_output)
    File.cp!(Path.join(roots.output, Web.marker()), Path.join(replacement_output, Web.marker()))
    File.chmod!(Path.join(replacement_output, Web.marker()), 0o600)
    File.write!(Path.join(replacement_output, "app.js"), "app")
    File.rename!(roots.output, moved_output)
    File.rename!(replacement_output, roots.output)

    try do
      assert {:error, :output_changed} = Web.revalidate_files(output_root, [descriptor])
    after
      File.rm_rf!(roots.output)
      File.rename!(moved_output, roots.output)
    end
  end

  test "root authority survives issuer exit and cannot be rebound", roots do
    base = Path.dirname(roots.input)
    issued_path = Path.join(base, "issued-root")
    replacement = Path.join(base, "replacement-root")
    moved = Path.join(base, "original-root")
    File.mkdir!(issued_path)
    File.mkdir!(replacement)
    File.write!(Path.join(issued_path, "member"), "same")
    File.write!(Path.join(replacement, "member"), "same")

    issued =
      Task.async(fn ->
        Web.root(issued_path, :read, id: "77777777777777777777777777777777")
      end)
      |> Task.await()

    assert {:ok, root} = issued
    assert {:ok, descriptor} = Web.file(root, "member")
    assert descriptor["sha256"] == :crypto.hash(:sha256, "same") |> Base.encode16(case: :lower)

    File.rename!(issued_path, moved)
    File.rename!(replacement, issued_path)

    try do
      assert {:error, :invalid_root} =
               Web.root(issued_path, :read, id: "77777777777777777777777777777777")

      assert {:error, :invalid_file} = Web.file(root, "member")
    after
      File.rm_rf!(issued_path)
      File.rename!(moved, issued_path)
    end
  end

  test "requires an exact no-follow attempt marker bound to the output root id", roots do
    assert {:error, :invalid_root} =
             Web.root(roots.output, :write_empty, id: "22222222222222222222222222222222")

    marker = Path.join(roots.output, Web.marker())
    target = Path.join(roots.input, "app.wasm")
    File.ln_s!(target, marker)

    assert {:error, :invalid_root} =
             Web.root(roots.output, :write_empty, id: "22222222222222222222222222222222")

    File.rm!(marker)

    assert {:ok, _root} =
             Web.prepare_output_root(roots.output,
               id: "22222222222222222222222222222222"
             )

    File.chmod!(marker, 0o700)

    assert {:error, :invalid_root} =
             Web.root(roots.output, :write_empty, id: "22222222222222222222222222222222")

    File.chmod!(marker, 0o600)

    assert {:error, :invalid_root} =
             Web.root(roots.output, :write_empty, id: "33333333333333333333333333333333")
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

    for code <-
          ~w[invalid_request incompatible_schema input_changed invalid_wasm bindgen_failed unsupported_import asset_escape asset_collision output_limit io_failed internal] do
      assert {:terminal, %{"code" => ^code}, _} =
               Web.accept(state, %{error | "code" => code})
    end
  end

  defp manifest_base do
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
        wasm_bindgen: "0.2.121",
        gpui_revision: String.duplicate("b", 40),
        helper_version: "0.1.0",
        helper_protocol: 1,
        compatibility_tuple_id: String.duplicate("c", 64)
      },
      host_requirements: %{secure_context: true, webgpu: true},
      hot_styles: []
    }
  end
end
