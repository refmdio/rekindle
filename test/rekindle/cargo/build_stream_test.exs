defmodule Rekindle.Cargo.BuildStreamTest do
  use ExUnit.Case, async: true

  alias Rekindle.Cargo.BuildStream

  @package_id "path+file:///workspace/client#rekindle-client@0.1.0"

  test "selects the declared Web artifact across every input split" do
    root = absolute("project")
    target_directory = Path.join(root, "target")
    artifact = Path.join(target_directory, "wasm32-unknown-unknown/debug/web.wasm")

    bytes =
      lines([
        compiler_message("warning", "unused value"),
        artifact_message("another package", "web", [artifact], nil),
        artifact_message(@package_id, "web", [artifact], nil),
        %{"reason" => "future-cargo-message", "value" => 1},
        %{"success" => true, "reason" => "build-finished"}
      ])

    for split <- 0..byte_size(bytes) do
      assert {:ok, stream} = stream(:web, root, target_directory)
      <<left::binary-size(^split), right::binary>> = bytes
      assert {:ok, stream} = BuildStream.push(stream, left)
      assert {:ok, stream} = BuildStream.push(stream, right)
      assert {:ok, result} = BuildStream.finish(stream, success_outcome())
      assert result.artifact == artifact
      assert Enum.any?(result.diagnostics, &(&1.code == :cargo_compiler))
      assert Enum.any?(result.diagnostics, &(&1.code == :cargo_unknown_message))
    end
  end

  test "uses executable rather than filenames for a native build" do
    root = absolute("project")
    target_directory = Path.join(root, "target")
    executable = Path.join(target_directory, "debug/desktop")
    misleading = Path.join(target_directory, "debug/desktop.wasm")

    assert {:ok, stream} = stream(:desktop, root, target_directory, target_name: "desktop")

    assert {:ok, stream} =
             BuildStream.push(
               stream,
               lines([
                 artifact_message(@package_id, "desktop", [misleading], executable),
                 %{"reason" => "build-finished", "success" => true}
               ])
             )

    assert {:ok, result} = BuildStream.finish(stream, success_outcome())
    assert result.artifact == executable
  end

  test "recognized messages with invalid schemas fail the protocol" do
    root = absolute("project")
    target_directory = Path.join(root, "target")

    malformed = [
      %{"reason" => "compiler-message", "message" => %{}},
      %{"reason" => "compiler-artifact", "package_id" => @package_id},
      %{"reason" => "build-script-executed", "package_id" => @package_id},
      %{"reason" => "build-finished", "success" => "yes"}
    ]

    for message <- malformed do
      assert {:ok, stream} = stream(:web, root, target_directory)

      assert {:error, %{code: :cargo_protocol}} =
               BuildStream.push(stream, Jason.encode!(message) <> "\n")
    end
  end

  test "non-JSON and unknown JSON are bounded diagnostics without authority" do
    root = absolute("project")
    target_directory = Path.join(root, "target")
    assert {:ok, stream} = stream(:web, root, target_directory, diagnostic_limit: 2)

    assert {:ok, stream} =
             BuildStream.push(stream, "plain output\n{\"reason\":\"new-kind\"}\nmore output\n")

    assert {:ok, stream} =
             BuildStream.push(
               stream,
               Jason.encode!(%{"reason" => "build-finished", "success" => true})
             )

    assert {:error, failure} = BuildStream.finish(stream, success_outcome())
    assert failure.code == :artifact_missing
    assert length(failure.diagnostics) == 2

    assert Enum.map(failure.diagnostics, & &1.code) == [
             :cargo_tool_output,
             :cargo_unknown_message
           ]
  end

  test "requires one final build-finished authority message" do
    root = absolute("project")
    target_directory = Path.join(root, "target")
    artifact = Path.join(target_directory, "debug/web.wasm")

    assert {:ok, stream} = stream(:web, root, target_directory)

    assert {:ok, stream} =
             BuildStream.push(stream, line(artifact_message(@package_id, "web", [artifact], nil)))

    assert {:error, %{code: :cargo_protocol}} = BuildStream.finish(stream, success_outcome())

    assert {:ok, stream} = stream(:web, root, target_directory)

    assert {:ok, stream} =
             BuildStream.push(stream, line(%{"reason" => "build-finished", "success" => true}))

    assert {:error, %{code: :cargo_protocol}} =
             BuildStream.push(stream, line(%{"reason" => "build-finished", "success" => true}))

    assert {:ok, stream} = stream(:web, root, target_directory)

    assert {:ok, stream} =
             BuildStream.push(stream, line(%{"reason" => "build-finished", "success" => true}))

    assert {:error, %{code: :cargo_protocol}} =
             BuildStream.push(stream, line(compiler_message("warning", "late")))
  end

  test "requires both Cargo success and a successful process outcome" do
    root = absolute("project")
    target_directory = Path.join(root, "target")
    artifact = Path.join(target_directory, "debug/web.wasm")

    messages = [
      artifact_message(@package_id, "web", [artifact], nil),
      %{"reason" => "build-finished", "success" => true}
    ]

    for {outcome, code} <- [
          {%{outcome: :exited, exit_code: 1, cleanup: :confirmed}, :cargo_failed},
          {%{outcome: :signaled, exit_code: nil, cleanup: :confirmed}, :cargo_failed},
          {%{outcome: :exited, exit_code: 0, cleanup: :uncertain}, :cleanup_unconfirmed},
          {:cancelled, :cancelled},
          {:timeout, :build_timeout}
        ] do
      assert {:ok, stream} = stream(:web, root, target_directory)
      assert {:ok, stream} = BuildStream.push(stream, lines(messages))
      assert {:error, failure} = BuildStream.finish(stream, outcome)
      assert failure.code == code
    end

    assert {:ok, stream} = stream(:web, root, target_directory)
    failed = List.replace_at(messages, 1, %{"reason" => "build-finished", "success" => false})
    assert {:ok, stream} = BuildStream.push(stream, lines(failed))
    assert {:error, %{code: :cargo_failed}} = BuildStream.finish(stream, success_outcome())
  end

  test "rejects ambiguous and escaped artifact reports" do
    root = absolute("project")
    target_directory = Path.join(root, "target")
    first = Path.join(target_directory, "debug/first.wasm")
    second = Path.join(target_directory, "debug/second.wasm")

    assert {:ok, stream} = stream(:web, root, target_directory)

    assert {:error, %{code: :artifact_ambiguous}} =
             BuildStream.push(
               stream,
               lines([
                 artifact_message(@package_id, "web", [first], nil),
                 artifact_message(@package_id, "web", [second], nil)
               ])
             )

    assert {:ok, stream} = stream(:web, root, target_directory)
    escaped = Path.join(root, "outside.wasm")

    assert {:error, %{code: :cargo_protocol}} =
             BuildStream.push(stream, line(artifact_message(@package_id, "web", [escaped], nil)))
  end

  test "enforces the logical line bound and processes an unterminated tail" do
    root = absolute("project")
    target_directory = Path.join(root, "target")

    assert {:ok, stream} = stream(:web, root, target_directory)
    assert {:ok, stream} = BuildStream.push(stream, :binary.copy("x", 1_048_576))
    assert {:ok, stream} = BuildStream.push(stream, "\n")

    assert {:error, %{code: :output_limit}} =
             BuildStream.push(stream, :binary.copy("x", 1_048_577))

    artifact = Path.join(target_directory, "debug/web.wasm")
    assert {:ok, stream} = stream(:web, root, target_directory)

    unterminated =
      line(artifact_message(@package_id, "web", [artifact], nil)) <>
        Jason.encode!(%{"reason" => "build-finished", "success" => true})

    assert {:ok, stream} = BuildStream.push(stream, unterminated)
    assert {:ok, %{artifact: ^artifact}} = BuildStream.finish(stream, success_outcome())
  end

  test "normalizes compiler locations without exposing external paths" do
    root = absolute("project")
    target_directory = Path.join(root, "target")
    artifact = Path.join(target_directory, "debug/web.wasm")

    message =
      compiler_message("error", "failed")
      |> put_in(["message", "spans"], [
        %{
          "file_name" => "/home/private/secret.rs",
          "line_start" => 9,
          "column_start" => 3,
          "is_primary" => true
        }
      ])

    assert {:ok, stream} = stream(:web, root, target_directory)

    assert {:ok, stream} =
             BuildStream.push(
               stream,
               lines([
                 message,
                 artifact_message(@package_id, "web", [artifact], nil),
                 %{"reason" => "build-finished", "success" => true}
               ])
             )

    assert {:ok, result} = BuildStream.finish(stream, success_outcome())
    diagnostic = Enum.find(result.diagnostics, &(&1.code == :cargo_compiler))
    assert diagnostic.file == "<external>"
    assert diagnostic.line == 9
    assert diagnostic.column == 3
  end

  defp stream(target, root, target_directory, options \\ []) do
    BuildStream.new(
      [
        target: target,
        package_id: @package_id,
        target_name: Keyword.get(options, :target_name, "web"),
        target_kind: ["bin"],
        target_directory: target_directory,
        project_root: root
      ] ++ options
    )
  end

  defp compiler_message(level, message) do
    %{
      "reason" => "compiler-message",
      "package_id" => @package_id,
      "target" => cargo_target("web"),
      "message" => %{
        "level" => level,
        "message" => message,
        "rendered" => message,
        "code" => nil,
        "spans" => []
      }
    }
  end

  defp artifact_message(package_id, name, filenames, executable) do
    %{
      "reason" => "compiler-artifact",
      "package_id" => package_id,
      "target" => cargo_target(name),
      "profile" => %{"test" => false},
      "features" => [],
      "filenames" => filenames,
      "executable" => executable,
      "fresh" => false
    }
  end

  defp cargo_target(name),
    do: %{"name" => name, "kind" => ["bin"], "crate_types" => ["bin"]}

  defp success_outcome,
    do: %{outcome: :exited, exit_code: 0, cleanup: :confirmed}

  defp lines(messages), do: Enum.map_join(messages, "", &line/1)
  defp line(message), do: Jason.encode!(message) <> "\n"
  defp absolute(name), do: Path.join(System.tmp_dir!(), "rekindle-build-stream-#{name}")
end
