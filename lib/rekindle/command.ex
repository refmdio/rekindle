defmodule Rekindle.Command do
  @moduledoc false

  require Logger

  alias Rekindle.{CanonicalValue, Failure, Redactor}

  @correlation ~r/correlation(?:_id)?=[0-9a-f]{32}/
  @max_stack_frames 12

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
      {:error, message} -> invocation_failure(command, argv, grammar, message)
    end
  end

  @spec emit(Outcome.t(), module()) :: non_neg_integer()
  def emit(%Outcome{} = outcome, shell \\ Mix.shell()) do
    if outcome.stdout != "", do: shell.info(String.trim_trailing(outcome.stdout))
    if outcome.stderr != "", do: shell.error(String.trim_trailing(outcome.stderr))
    outcome.exit_status
  end

  @spec emit_and_exit(Outcome.t(), module()) :: :ok | no_return()
  def emit_and_exit(%Outcome{} = outcome, shell \\ Mix.shell()) do
    case emit(outcome, shell) do
      0 -> :ok
      status when status in 1..3 -> exit({:shutdown, status})
    end
  end

  defp parse(argv, grammar) do
    switches = Keyword.fetch!(grammar, :switches)
    aliases = Keyword.get(grammar, :aliases, [])
    positional_count = Keyword.get(grammar, :positionals, 0)

    with :ok <- validate_raw_options(argv, switches, aliases) do
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
  end

  defp validate_raw_options(argv, switches, aliases) do
    {long, short} = raw_option_maps(switches, aliases)

    scan_raw_options(argv, long, short, MapSet.new())
  end

  defp raw_option_maps(switches, aliases) do
    specifications = Map.new(switches)

    long =
      Map.new(switches, fn {name, type} ->
        {"--" <> (name |> Atom.to_string() |> String.replace("_", "-")), {name, type}}
      end)

    short =
      Enum.reduce(aliases, %{}, fn {alias_name, name}, result ->
        case Map.fetch(specifications, name) do
          {:ok, type} -> Map.put(result, "-" <> Atom.to_string(alias_name), {name, type})
          :error -> result
        end
      end)

    {long, short}
  end

  defp scan_raw_options([], _long, _short, _seen), do: :ok

  defp scan_raw_options(["--" | _rest], _long, _short, _seen),
    do: {:error, "unknown or invalid option: --"}

  defp scan_raw_options(["--" <> _rest = token | rest], long, short, seen) do
    case raw_long_option(token, long) do
      {:ok, name, type, consume_value?} ->
        continue_raw_options(rest, long, short, seen, token, name, type, consume_value?)

      :error ->
        {:error, "unknown or invalid option: #{token}"}
    end
  end

  defp scan_raw_options(["-" <> rest = token | tail], long, short, seen) when rest != "" do
    case raw_short_option(token, short) do
      {:ok, name, type, consume_value?} ->
        continue_raw_options(tail, long, short, seen, token, name, type, consume_value?)

      :error ->
        {:error, "unknown or invalid option: #{token}"}
    end
  end

  defp scan_raw_options([_positional | rest], long, short, seen),
    do: scan_raw_options(rest, long, short, seen)

  defp raw_long_option(token, long) do
    case Map.fetch(long, token) do
      {:ok, {name, type}} ->
        {:ok, name, type, value_option?(type)}

      :error ->
        with [spelling, _value] <- String.split(token, "=", parts: 2),
             {:ok, {name, type}} <- Map.fetch(long, spelling),
             true <- value_option?(type) do
          {:ok, name, type, false}
        else
          _ -> :error
        end
    end
  end

  defp raw_short_option(token, short) do
    case Map.fetch(short, token) do
      {:ok, {name, type}} ->
        {:ok, name, type, value_option?(type)}

      :error ->
        with [spelling, _value] <- String.split(token, "=", parts: 2),
             {:ok, {name, type}} <- Map.fetch(short, spelling),
             true <- value_option?(type) do
          {:ok, name, type, false}
        else
          _ -> :error
        end
    end
  end

  defp continue_raw_options(rest, long, short, seen, token, name, type, consume_value?) do
    if not repeatable_option?(type) and MapSet.member?(seen, name) do
      {:error, "duplicate option: #{token}"}
    else
      rest = if consume_value?, do: drop_option_value(rest, type), else: rest
      scan_raw_options(rest, long, short, MapSet.put(seen, name))
    end
  end

  defp repeatable_option?(type), do: type in [:count, :keep]
  defp value_option?(type), do: type in [:float, :integer, :keep, :string]

  defp drop_option_value([], _type), do: []

  defp drop_option_value([value | tail] = values, type) do
    if separated_option_value?(value, type), do: tail, else: values
  end

  defp separated_option_value?("-", type) when type in [:float, :integer, :keep, :string],
    do: true

  defp separated_option_value?("-" <> <<digit, _rest::binary>>, type)
       when digit in ?0..?9 and type in [:float, :integer, :keep, :string],
       do: true

  defp separated_option_value?("-" <> _rest, _type), do: false
  defp separated_option_value?(_value, _type), do: true

  defp execute(command, invocation, handler) do
    case handler.(invocation) do
      {:ok, result} ->
        success(command, invocation, result, [])

      {:ok, result, progress} ->
        success(command, invocation, result, progress)

      {:error, %Failure{stage: :internal} = failure} ->
        internal_failure(command, invocation, {:typed_failure, failure})

      {:error, %Failure{stage: :internal} = failure, _progress} ->
        internal_failure(command, invocation, {:typed_failure, failure})

      {:error, :invocation, %Failure{stage: :internal} = failure} ->
        internal_failure(command, invocation, {:typed_failure, failure})

      {:error, %Failure{} = failure} ->
        expected_failure(command, invocation, failure, [])

      {:error, %Failure{} = failure, progress} ->
        expected_failure(command, invocation, failure, progress)

      {:error, :invocation, %Failure{} = failure} ->
        invalid_invocation(command, invocation, failure)

      _ ->
        internal_failure(
          command,
          invocation,
          {:boundary, "handler returned an invalid terminal value"}
        )
    end
  rescue
    exception ->
      internal_failure(command, invocation, {:raised, exception, __STACKTRACE__})
  catch
    kind, reason ->
      internal_failure(command, invocation, {:caught, kind, reason, __STACKTRACE__})
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
    exception ->
      internal_failure(command, %{json?: true}, {:raised, exception, __STACKTRACE__})
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
    case Failure.sanitize(failure) do
      {:ok, failure} ->
        failure_outcome(command, true, failure, [], 1)

      {:error, _} ->
        internal_failure(command, %{json?: true}, {:boundary, "unsafe failure payload"})
    end
  end

  defp expected_failure(_command, %{json?: false}, failure, progress) do
    case Failure.sanitize(failure) do
      {:ok, failure} ->
        failure_outcome(nil, false, failure, progress, 1)

      {:error, _} ->
        internal_failure(nil, %{json?: false}, {:boundary, "unsafe failure payload"})
    end
  end

  defp invalid_invocation(command, invocation, failure) do
    case Failure.sanitize(failure) do
      {:ok, failure} ->
        failure_outcome(command, invocation.json?, failure, [], 2)

      {:error, _} ->
        internal_failure(command, invocation, {:boundary, "unsafe invocation failure payload"})
    end
  end

  defp invocation_failure(command, argv, grammar, message) do
    json? = json_intent?(argv, grammar)

    failure =
      Failure.new!(target: nil, stage: :configuration, code: :config_invalid, message: message)

    failure_outcome(command, json?, failure, [], 2)
  end

  defp json_intent?(argv, grammar) do
    switches = Keyword.fetch!(grammar, :switches)

    if Keyword.get(switches, :json) == :boolean do
      {long, short} = raw_option_maps(switches, Keyword.get(grammar, :aliases, []))
      scan_json_intent?(argv, long, short)
    else
      false
    end
  end

  defp scan_json_intent?([], _long, _short), do: false
  defp scan_json_intent?(["--" | _rest], _long, _short), do: false

  defp scan_json_intent?(["--" <> _rest = token | tail], long, short) do
    json_option_or_continue?(raw_long_option(token, long), tail, long, short)
  end

  defp scan_json_intent?(["-" <> rest = token | tail], long, short) when rest != "" do
    json_option_or_continue?(raw_short_option(token, short), tail, long, short)
  end

  defp scan_json_intent?([_value | tail], long, short),
    do: scan_json_intent?(tail, long, short)

  defp json_option_or_continue?({:ok, :json, :boolean, false}, _tail, _long, _short),
    do: true

  defp json_option_or_continue?({:ok, _name, type, true}, tail, long, short),
    do: scan_json_intent?(drop_option_value(tail, type), long, short)

  defp json_option_or_continue?(_option, tail, long, short),
    do: scan_json_intent?(tail, long, short)

  defp failure_outcome(command, true, failure, _progress, exit_status) do
    envelope = envelope(command, "error", nil, Failure.to_map(failure))

    %Outcome{
      exit_status: exit_status,
      stdout: CanonicalValue.encode!(envelope) <> "\n",
      stderr: "",
      value: {:error, failure}
    }
  end

  defp failure_outcome(_command, false, failure, progress, exit_status) do
    %Outcome{
      exit_status: exit_status,
      stdout: lines(progress),
      stderr: Failure.render(failure) <> "\n",
      value: {:error, failure}
    }
  end

  defp internal_failure(command, invocation, context) do
    correlation = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    log_internal_failure(command, correlation, context)

    failure =
      Failure.new!(
        target: nil,
        stage: :internal,
        code: :contract_violation,
        message: "internal command failure; correlation=#{correlation}"
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

  defp log_internal_failure(command, correlation, context) do
    command = sanitize_context({:command, command})
    context = sanitize_context(context)

    Logger.error(
      "Rekindle internal command failure correlation=#{correlation} command=#{command} context=#{context}"
    )
  end

  defp sanitize_context(context) do
    context
    |> format_context()
    |> String.replace(@correlation, "correlation=<redacted>")
    |> Redactor.sanitize()
    |> case do
      {:ok, value} -> value
      {:error, _reason} -> "diagnostic context unavailable"
    end
  rescue
    _ -> "diagnostic context unavailable"
  catch
    _, _ -> "diagnostic context unavailable"
  end

  defp format_context({:command, command}) when is_binary(command), do: command
  defp format_context({:command, _command}), do: "unknown"
  defp format_context({:boundary, message}) when is_binary(message), do: message

  defp format_context({:typed_failure, failure}) do
    case Failure.sanitize(failure) do
      {:ok, failure} ->
        "kind=typed_failure stage=#{failure.stage} code=#{failure.code} " <>
          "message=#{failure.message} diagnostics=#{length(failure.diagnostics)}"

      {:error, _reason} ->
        "kind=typed_failure payload=unsafe"
    end
  end

  defp format_context({:raised, exception, stacktrace}) do
    "kind=raise exception=#{exception_name(exception)} message=#{exception_message(exception)} " <>
      "stack=#{format_stack(stacktrace)}"
  end

  defp format_context({:caught, kind, reason, stacktrace}) do
    "kind=#{safe_kind(kind)} reason=#{safe_inspect(reason)} stack=#{format_stack(stacktrace)}"
  end

  defp format_context(_context), do: "diagnostic context unavailable"

  defp exception_name(%{__struct__: module}) when is_atom(module), do: inspect(module)
  defp exception_name(_exception), do: "unknown"

  defp exception_message(exception) do
    Exception.message(exception)
  rescue
    _ -> "unavailable"
  end

  defp safe_kind(kind) when kind in [:throw, :exit, :error], do: Atom.to_string(kind)
  defp safe_kind(_kind), do: "unknown"

  defp safe_inspect(value) do
    inspect(value, limit: 20, printable_limit: 2_048, width: 120)
  rescue
    _ -> "unavailable"
  catch
    _, _ -> "unavailable"
  end

  defp format_stack(stacktrace) when is_list(stacktrace) do
    stacktrace
    |> Enum.take(@max_stack_frames)
    |> Enum.map_join(",", &format_frame/1)
  end

  defp format_stack(_stacktrace), do: "unavailable"

  defp format_frame({module, function, arity_or_arguments, metadata})
       when is_atom(module) and is_atom(function) and is_list(metadata) do
    arity = if is_integer(arity_or_arguments), do: arity_or_arguments, else: "?"
    line = Keyword.get(metadata, :line, "?")
    "#{inspect(module)}.#{function}/#{arity}:#{line}"
  end

  defp format_frame(_frame), do: "unknown"

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
