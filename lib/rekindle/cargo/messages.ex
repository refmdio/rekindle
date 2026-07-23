defmodule Rekindle.Cargo.Messages do
  @moduledoc false

  alias Rekindle.Cargo.Error
  alias Rekindle.Diagnostic

  @spec decode(Rekindle.Cargo.Process.t(), String.t(), String.t(), :web | :desktop) ::
          {:ok, Path.t(), [Diagnostic.t()], String.t()} | {:error, Error.t()}
  def decode(process, package_id, binary, target) do
    {artifact, diagnostics, output} =
      process.output
      |> String.split("\n", trim: true)
      |> Enum.reduce({nil, [], []}, fn line, {artifact, diagnostics, output} ->
        case Jason.decode(line) do
          {:ok, %{"reason" => "compiler-artifact"} = message} ->
            {matching_artifact(message, package_id, binary, target) || artifact, diagnostics,
             output}

          {:ok, %{"reason" => "compiler-message", "message" => message}} ->
            {artifact, [diagnostic(message) | diagnostics], output}

          {:ok, _message} ->
            {artifact, diagnostics, output}

          {:error, _reason} ->
            {artifact, diagnostics, [line | output]}
        end
      end)

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
