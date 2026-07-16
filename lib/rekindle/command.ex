defmodule Rekindle.Command do
  @moduledoc false

  alias Rekindle.{CanonicalValue, Failure}

  defmodule Outcome do
    @moduledoc false
    @enforce_keys [:exit_status, :stdout, :stderr, :value]
    defstruct [:exit_status, :stdout, :stderr, :value]

    @type t :: %__MODULE__{
            exit_status: 0 | 1 | 2 | 3,
            stdout: String.t(),
            stderr: String.t(),
            value: {:ok, term()} | {:error, Rekindle.Failure.t()}
          }
  end

  @spec run(String.t(), [String.t()], keyword(), (map() -> term())) :: Outcome.t()
  def run(command, argv, grammar, handler) when is_function(handler, 1) do
    case parse(argv, grammar) do
      {:ok, invocation} -> execute(command, invocation, handler)
      {:error, message} -> invocation_failure(command, argv, message)
    end
  end

  @spec emit(Outcome.t(), module()) :: non_neg_integer()
  def emit(%Outcome{} = outcome, shell \\ Mix.shell()) do
    if outcome.stdout != "", do: shell.info(String.trim_trailing(outcome.stdout))
    if outcome.stderr != "", do: shell.error(String.trim_trailing(outcome.stderr))
    outcome.exit_status
  end

  defp parse(argv, grammar) do
    switches = Keyword.fetch!(grammar, :switches)
    aliases = Keyword.get(grammar, :aliases, [])
    positional_count = Keyword.get(grammar, :positionals, 0)

    case OptionParser.parse(argv, strict: switches, aliases: aliases) do
      {options, positionals, []} when length(positionals) == positional_count ->
        {:ok,
         %{
           options: Map.new(options),
           positionals: positionals,
           json?: Keyword.get(options, :json, false)
         }}

      {_options, _positionals, invalid} when invalid != [] ->
        {:error, "unknown or invalid option: #{format_invalid(invalid)}"}

      _ ->
        {:error, "invalid positional arguments"}
    end
  end

  defp execute(command, invocation, handler) do
    case handler.(invocation) do
      {:ok, result} ->
        success(command, invocation, result, [])

      {:ok, result, progress} ->
        success(command, invocation, result, progress)

      {:error, %Failure{} = failure} ->
        expected_failure(command, invocation, failure, [])

      {:error, %Failure{} = failure, progress} ->
        expected_failure(command, invocation, failure, progress)

      _ ->
        internal_failure(command, invocation, "handler returned an invalid terminal value")
    end
  rescue
    _exception -> internal_failure(command, invocation, "command handler raised unexpectedly")
  catch
    _kind, _reason ->
      internal_failure(command, invocation, "command handler terminated unexpectedly")
  end

  defp success(command, %{json?: true}, result, _progress) do
    envelope = envelope(command, "ok", canonical_result(result), nil)

    %Outcome{
      exit_status: 0,
      stdout: CanonicalValue.encode!(envelope) <> "\n",
      stderr: "",
      value: {:ok, result}
    }
  rescue
    _ -> internal_failure(command, %{json?: true}, "success result is not canonical")
  end

  defp success(_command, %{json?: false}, result, progress) do
    terminal = human_result(result)

    %Outcome{
      exit_status: 0,
      stdout: lines(progress ++ [terminal]),
      stderr: "",
      value: {:ok, result}
    }
  end

  defp expected_failure(command, %{json?: true}, failure, _progress) do
    envelope = envelope(command, "error", nil, Failure.to_map(failure))

    %Outcome{
      exit_status: 1,
      stdout: CanonicalValue.encode!(envelope) <> "\n",
      stderr: "",
      value: {:error, failure}
    }
  end

  defp expected_failure(_command, %{json?: false}, failure, progress) do
    %Outcome{
      exit_status: 1,
      stdout: lines(progress),
      stderr: Failure.render(failure) <> "\n",
      value: {:error, failure}
    }
  end

  defp invocation_failure(command, argv, message) do
    json? = "--json" in argv

    failure =
      Failure.new!(target: nil, stage: :configuration, code: :config_invalid, message: message)

    if json? do
      envelope = envelope(command, "error", nil, Failure.to_map(failure))

      %Outcome{
        exit_status: 2,
        stdout: CanonicalValue.encode!(envelope) <> "\n",
        stderr: "",
        value: {:error, failure}
      }
    else
      %Outcome{
        exit_status: 2,
        stdout: "",
        stderr: Failure.render(failure) <> "\n",
        value: {:error, failure}
      }
    end
  end

  defp internal_failure(command, invocation, message) do
    correlation = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    failure =
      Failure.new!(
        target: nil,
        stage: :internal,
        code: :contract_violation,
        message: "#{message}; correlation=#{correlation}"
      )

    if invocation.json? do
      envelope = envelope(command, "error", nil, Failure.to_map(failure))

      %Outcome{
        exit_status: 3,
        stdout: CanonicalValue.encode!(envelope) <> "\n",
        stderr: "",
        value: {:error, failure}
      }
    else
      %Outcome{
        exit_status: 3,
        stdout: "",
        stderr: Failure.render(failure) <> "\n",
        value: {:error, failure}
      }
    end
  end

  defp envelope(command, status, result, failure) do
    %{
      "contract_version" => 1,
      "command" => command,
      "status" => status,
      "result" => result,
      "failure" => failure
    }
  end

  defp canonical_result(value) when is_map(value), do: stringify(value)
  defp canonical_result(value), do: value

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp stringify(value), do: value

  defp human_result(value) when is_binary(value), do: value
  defp human_result(value), do: value |> canonical_result() |> CanonicalValue.encode!()
  defp lines([]), do: ""
  defp lines(values), do: Enum.map_join(values, "", &(&1 <> "\n"))

  defp format_invalid(values),
    do: Enum.map_join(values, ", ", fn {name, value} -> "#{name}=#{inspect(value)}" end)
end
