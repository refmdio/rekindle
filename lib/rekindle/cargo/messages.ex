defmodule Rekindle.Cargo.Messages do
  @moduledoc false

  alias Rekindle.Cargo.Error
  alias Rekindle.Diagnostic

  @spec decode(Rekindle.Toolchain.Process.t(), String.t(), String.t(), :web | :desktop) ::
          {:ok, Path.t(), [Diagnostic.t()], String.t()} | {:error, Error.t()}
  def decode(process, package_id, binary, target) do
    result =
      process.output
      |> String.split("\n", trim: true)
      |> Enum.reduce_while({nil, [], []}, fn line, {artifact, diagnostics, output} ->
        case Jason.decode(line) do
          {:ok, %{"reason" => "compiler-artifact"} = message} ->
            if artifact_message?(message) do
              {:cont,
               {matching_artifact(message, package_id, binary, target) || artifact, diagnostics,
                output}}
            else
              {:halt, invalid_message("compiler-artifact", line)}
            end

          {:ok, %{"reason" => "compiler-message", "message" => message}} ->
            if diagnostic_message?(message) do
              {:cont, {artifact, [diagnostic(message) | diagnostics], output}}
            else
              {:halt, invalid_message("compiler-message", line)}
            end

          {:ok, %{"reason" => "compiler-message"}} ->
            {:halt, invalid_message("compiler-message", line)}

          {:ok, _message} ->
            {:cont, {artifact, diagnostics, output}}

          {:error, _reason} ->
            {:cont, {artifact, diagnostics, [line | output]}}
        end
      end)

    finish(result, process, target)
  end

  defp finish({:error, _error} = result, _process, _target), do: result

  defp finish({artifact, diagnostics, output}, process, target) do
    diagnostics = Enum.reverse(diagnostics)
    output = output |> Enum.reverse() |> Enum.join("\n")
    diagnostics = failure_diagnostic(process.status, diagnostics, output)

    cond do
      process.truncated? ->
        {:error,
         Error.new(:output_limit, "cargo build exceeded the output limit",
           diagnostics: diagnostics,
           output: output
         )}

      process.status != 0 ->
        {:error,
         Error.new(:build_failed, "cargo build failed with status #{process.status}",
           diagnostics: diagnostics,
           output: output
         )}

      is_nil(artifact) ->
        {:error,
         Error.new(
           :artifact_not_found,
           "cargo build succeeded without a matching #{target} artifact"
         )}

      true ->
        {:ok, artifact, diagnostics, output}
    end
  end

  defp artifact_message?(message) do
    is_binary(message["package_id"]) and
      match?(
        %{"name" => name, "kind" => kind}
        when is_binary(name) and is_list(kind),
        message["target"]
      ) and
      Enum.all?(message["target"]["kind"], &is_binary/1) and
      is_list(message["filenames"]) and
      Enum.all?(message["filenames"], &is_binary/1) and
      (is_nil(message["executable"]) or is_binary(message["executable"]))
  end

  defp diagnostic_message?(message) when is_map(message) do
    is_binary(message["level"]) and
      is_binary(message["message"]) and
      (is_nil(message["rendered"]) or is_binary(message["rendered"])) and
      is_list(message["spans"]) and
      Enum.all?(message["spans"], &span?/1)
  end

  defp diagnostic_message?(_message), do: false

  defp span?(%{"is_primary" => false}), do: true

  defp span?(%{
         "is_primary" => true,
         "file_name" => file,
         "line_start" => line
       })
       when is_binary(file) and is_integer(line),
       do: true

  defp span?(_span), do: false

  defp invalid_message(reason, output) do
    {:error,
     Error.new(:invalid_message, "cargo returned a malformed #{reason} message", output: output)}
  end

  defp matching_artifact(message, package_id, binary, target) do
    matching? =
      message["package_id"] == package_id and
        message["target"]["name"] == binary and
        "bin" in message["target"]["kind"]

    if matching? do
      artifact(message, target)
    end
  end

  defp artifact(message, :web),
    do: Enum.find(message["filenames"], &String.ends_with?(&1, ".wasm"))

  defp artifact(message, :desktop), do: message["executable"]

  defp diagnostic(message) do
    primary = Enum.find(message["spans"], & &1["is_primary"])

    %Diagnostic{
      severity: severity(message["level"]),
      source: :cargo,
      message: message["message"],
      file: primary && primary["file_name"],
      line: primary && primary["line_start"],
      rendered: message["rendered"]
    }
  end

  defp severity("error"), do: :error
  defp severity("warning"), do: :warning
  defp severity(_), do: :info

  defp failure_diagnostic(0, diagnostics, _output), do: diagnostics
  defp failure_diagnostic(_status, [_ | _] = diagnostics, _output), do: diagnostics

  defp failure_diagnostic(_status, [], output) when output != "" do
    [
      %Diagnostic{
        severity: :error,
        source: :cargo,
        message: "Cargo compilation failed",
        rendered: output
      }
    ]
  end

  defp failure_diagnostic(_status, [], _output), do: []
end
