defmodule Rekindle.Cargo.BuildStream do
  @moduledoc false

  alias Rekindle.{Diagnostic, ExecutionResult, Failure}

  @maximum_line_bytes 1_048_576
  @default_diagnostic_limit 512

  @recognized_reasons ~w[compiler-message compiler-artifact build-script-executed build-finished]

  @enforce_keys [
    :target,
    :package_id,
    :target_name,
    :target_kind,
    :target_directory,
    :project_root,
    :expected_test,
    :diagnostic_limit
  ]
  defstruct @enforce_keys ++
              [buffer: <<>>, diagnostics: [], artifact: nil, build_finished: nil]

  defmodule Result do
    @moduledoc false
    @enforce_keys [:target, :artifact, :diagnostics]
    defstruct @enforce_keys
  end

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: {:ok, t()} | {:error, Failure.t()}
  def new(options) when is_list(options) do
    target = Keyword.get(options, :target)
    package_id = Keyword.get(options, :package_id)
    target_name = Keyword.get(options, :target_name)
    target_kind = Keyword.get(options, :target_kind, ["bin"])
    target_directory = Keyword.get(options, :target_directory)
    project_root = Keyword.get(options, :project_root)
    expected_test = Keyword.get(options, :test, false)
    diagnostic_limit = Keyword.get(options, :diagnostic_limit, @default_diagnostic_limit)

    if target in [:web, :desktop] and safe_string?(package_id) and
         safe_string?(target_name) and string_list?(target_kind) and target_kind != [] and
         target_kind == Enum.sort(Enum.uniq(target_kind)) and
         normalized_absolute_path?(target_directory) and
         normalized_absolute_path?(project_root) and
         is_boolean(expected_test) and diagnostic_limit in 1..4_096 do
      {:ok,
       %__MODULE__{
         target: target,
         package_id: package_id,
         target_name: target_name,
         target_kind: Enum.sort(target_kind),
         target_directory: Path.expand(target_directory),
         project_root: Path.expand(project_root),
         expected_test: expected_test,
         diagnostic_limit: diagnostic_limit
       }}
    else
      failure(target, :cargo_protocol, "Cargo build stream configuration is invalid")
    end
  end

  def new(_options),
    do: failure(nil, :cargo_protocol, "Cargo build stream configuration is invalid")

  @spec push(t(), binary()) :: {:ok, t()} | {:error, Failure.t()}
  def push(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    consume(state, state.buffer <> chunk)
  rescue
    _ -> failure(state.target, :cargo_protocol, "Cargo build output could not be decoded", state)
  end

  def push(%__MODULE__{} = state, _chunk),
    do: failure(state.target, :cargo_protocol, "Cargo stdout chunk is invalid", state)

  @spec push_stderr(t(), binary()) :: {:ok, t()} | {:error, Failure.t()}
  def push_stderr(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    {:ok, add_opaque_diagnostic(state, :cargo_tool_output, "Cargo stderr", chunk)}
  end

  def push_stderr(%__MODULE__{} = state, _chunk),
    do: failure(state.target, :cargo_protocol, "Cargo stderr chunk is invalid", state)

  @spec finish(t(), ExecutionResult.t() | map() | atom()) ::
          {:ok, Result.t()} | {:error, Failure.t()}
  def finish(%__MODULE__{} = state, outcome) do
    with {:ok, state} <- consume_tail(state),
         :ok <- validate_process_outcome(state, outcome),
         :ok <- validate_build_finished(state),
         {:ok, artifact} <- selected_artifact(state) do
      {:ok,
       %Result{
         target: state.target,
         artifact: artifact,
         diagnostics: Enum.reverse(state.diagnostics)
       }}
    end
  end

  defp consume(state, bytes) do
    case :binary.match(bytes, "\n") do
      {index, 1} ->
        line = binary_part(bytes, 0, index)
        rest = binary_part(bytes, index + 1, byte_size(bytes) - index - 1)

        if byte_size(line) > @maximum_line_bytes do
          failure(state.target, :output_limit, "Cargo stdout line exceeds 1 MiB", state)
        else
          with {:ok, state} <- decode_line(%{state | buffer: <<>>}, line) do
            consume(state, rest)
          end
        end

      :nomatch when byte_size(bytes) > @maximum_line_bytes ->
        failure(state.target, :output_limit, "Cargo stdout line exceeds 1 MiB", state)

      :nomatch ->
        {:ok, %{state | buffer: bytes}}
    end
  end

  defp consume_tail(%__MODULE__{buffer: <<>>} = state), do: {:ok, state}

  defp consume_tail(%__MODULE__{} = state) do
    decode_line(%{state | buffer: <<>>}, state.buffer)
  end

  defp decode_line(state, <<>>), do: {:ok, state}

  defp decode_line(state, line) do
    case Jason.decode(line) do
      {:ok, %{"reason" => reason} = message} when reason in @recognized_reasons ->
        if state.build_finished == true or state.build_finished == false do
          failure(
            state.target,
            :cargo_protocol,
            "Cargo emitted a recognized message after build-finished",
            state
          )
        else
          decode_recognized(state, reason, message)
        end

      {:ok, _unknown} ->
        {:ok,
         add_opaque_diagnostic(
           state,
           :cargo_unknown_message,
           "Unknown Cargo JSON message",
           line
         )}

      {:error, _reason} ->
        {:ok, add_opaque_diagnostic(state, :cargo_tool_output, "Non-JSON Cargo stdout", line)}
    end
  end

  defp decode_recognized(state, "compiler-message", message) do
    with {:ok, diagnostic} <- compiler_diagnostic(state, message) do
      {:ok, add_diagnostic(state, diagnostic)}
    else
      _ -> malformed(state, "compiler-message")
    end
  end

  defp decode_recognized(state, "compiler-artifact", message) do
    case compiler_artifact(state, message) do
      {:ok, :unrelated} -> {:ok, state}
      {:ok, artifact} -> put_artifact(state, artifact)
      _ -> malformed(state, "compiler-artifact")
    end
  end

  defp decode_recognized(state, "build-script-executed", message) do
    if valid_build_script?(message),
      do: {:ok, state},
      else: malformed(state, "build-script-executed")
  end

  defp decode_recognized(state, "build-finished", %{"success" => success})
       when is_boolean(success) do
    {:ok, %{state | build_finished: success}}
  end

  defp decode_recognized(state, "build-finished", _message),
    do: malformed(state, "build-finished")

  defp compiler_diagnostic(
         state,
         %{
           "package_id" => package_id,
           "target" => target,
           "message" => %{"level" => level, "message" => message} = body
         }
       )
       when is_binary(package_id) and is_binary(level) and is_binary(message) do
    with :ok <- valid_target(target),
         :ok <- optional_string(Map.get(body, "rendered")),
         :ok <- optional_code(Map.get(body, "code")),
         :ok <- valid_spans(Map.get(body, "spans", [])),
         {:ok, diagnostic} <-
           Diagnostic.new(
             [
               target: state.target,
               stage: :execution,
               severity: severity(level),
               code: :cargo_compiler,
               message: bounded_text(message, 4_096),
               rendered: bounded_optional(Map.get(body, "rendered"), 16_384)
             ] ++ location(state, Map.get(body, "spans", []))
           ) do
      {:ok, diagnostic}
    end
  end

  defp compiler_diagnostic(_state, _message), do: :error

  defp compiler_artifact(
         state,
         %{
           "package_id" => package_id,
           "target" => target,
           "profile" => %{"test" => test?},
           "features" => features,
           "filenames" => filenames,
           "executable" => executable,
           "fresh" => fresh
         }
       )
       when is_binary(package_id) and is_boolean(test?) and is_boolean(fresh) do
    with :ok <- valid_target(target),
         true <- string_list?(features),
         true <- absolute_path_list?(filenames),
         :ok <- optional_absolute_path(executable) do
      if matching_artifact?(state, package_id, target, test?) do
        select_candidate(state, filenames, executable)
      else
        {:ok, :unrelated}
      end
    else
      _ -> :error
    end
  end

  defp compiler_artifact(_state, _message), do: :error

  defp matching_artifact?(state, package_id, target, test?) do
    package_id == state.package_id and target["name"] == state.target_name and
      Enum.sort(target["kind"]) == state.target_kind and test? == state.expected_test
  end

  defp select_candidate(%{target: :web} = state, filenames, _executable) do
    candidates = Enum.filter(filenames, &(Path.extname(&1) == ".wasm"))

    case candidates do
      [path] -> contained_candidate(state, path)
      [] -> {:ok, :unrelated}
      _ -> :error
    end
  end

  defp select_candidate(%{target: :desktop} = state, _filenames, executable)
       when is_binary(executable),
       do: contained_candidate(state, executable)

  defp select_candidate(%{target: :desktop}, _filenames, nil), do: {:ok, :unrelated}

  defp contained_candidate(state, path) do
    path = Path.expand(path)

    if descendant?(path, state.target_directory),
      do: {:ok, path},
      else: :error
  end

  defp put_artifact(%{artifact: nil} = state, artifact),
    do: {:ok, %{state | artifact: artifact}}

  defp put_artifact(state, _artifact) do
    failure(
      state.target,
      :artifact_ambiguous,
      "Cargo reported multiple matching artifacts",
      state
    )
  end

  defp selected_artifact(%{artifact: nil} = state),
    do:
      failure(state.target, :artifact_missing, "Cargo did not report a matching artifact", state)

  defp selected_artifact(%{artifact: artifact}), do: {:ok, artifact}

  defp validate_process_outcome(state, %ExecutionResult{cleanup: :uncertain}),
    do:
      failure(
        state.target,
        :cleanup_unconfirmed,
        "Cargo process cleanup was not confirmed",
        state
      )

  defp validate_process_outcome(_state, %ExecutionResult{
         outcome: :exited,
         exit_code: 0,
         cleanup: :confirmed
       }),
       do: :ok

  defp validate_process_outcome(state, %ExecutionResult{}),
    do: failure(state.target, :cargo_failed, "Cargo process did not exit successfully", state)

  defp validate_process_outcome(state, %{cleanup: :uncertain}),
    do:
      failure(
        state.target,
        :cleanup_unconfirmed,
        "Cargo process cleanup was not confirmed",
        state
      )

  defp validate_process_outcome(_state, %{outcome: :exited, exit_code: 0, cleanup: :confirmed}),
    do: :ok

  defp validate_process_outcome(state, :cancelled),
    do: failure(state.target, :cancelled, "Cargo build was cancelled", state)

  defp validate_process_outcome(state, :timeout),
    do: failure(state.target, :build_timeout, "Cargo build timed out", state)

  defp validate_process_outcome(state, _outcome),
    do: failure(state.target, :cargo_failed, "Cargo process did not exit successfully", state)

  defp validate_build_finished(%{build_finished: true}), do: :ok

  defp validate_build_finished(%{build_finished: false} = state),
    do: failure(state.target, :cargo_failed, "Cargo reported an unsuccessful build", state)

  defp validate_build_finished(state),
    do: failure(state.target, :cargo_protocol, "Cargo did not emit build-finished", state)

  defp valid_target(%{"name" => name, "kind" => kind, "crate_types" => crate_types}) do
    if safe_string?(name) and string_list?(kind) and kind != [] and string_list?(crate_types),
      do: :ok,
      else: :error
  end

  defp valid_target(_target), do: :error

  defp valid_build_script?(%{
         "package_id" => package_id,
         "linked_libs" => linked_libs,
         "linked_paths" => linked_paths,
         "cfgs" => cfgs,
         "env" => env,
         "out_dir" => out_dir
       }) do
    safe_string?(package_id) and string_list?(linked_libs) and string_list?(linked_paths) and
      string_list?(cfgs) and env_list?(env) and absolute_path?(out_dir)
  end

  defp valid_build_script?(_message), do: false

  defp valid_spans(spans) when is_list(spans) do
    if proper_list?(spans) and
         Enum.all?(spans, fn
           %{"file_name" => file, "line_start" => line, "column_start" => column}
           when is_binary(file) and is_integer(line) and line > 0 and is_integer(column) and
                  column > 0 ->
             true

           _ ->
             false
         end),
       do: :ok,
       else: :error
  end

  defp valid_spans(_spans), do: false

  defp optional_code(nil), do: :ok
  defp optional_code(%{"code" => code}) when is_binary(code), do: :ok
  defp optional_code(_code), do: :error

  defp location(_state, []), do: []

  defp location(state, spans) do
    span = Enum.find(spans, &Map.get(&1, "is_primary", false)) || List.first(spans)
    file = diagnostic_file(state.project_root, span["file_name"])
    [file: file, line: span["line_start"], column: span["column_start"]]
  end

  defp diagnostic_file(project_root, path) do
    expanded = Path.expand(path, project_root)

    if descendant?(expanded, project_root) do
      Path.relative_to(expanded, project_root)
    else
      "<external>"
    end
  end

  defp severity("error"), do: :error
  defp severity("warning"), do: :warning
  defp severity(_level), do: :info

  defp add_opaque_diagnostic(state, code, label, bytes) do
    message = label <> ": " <> inspect(bytes, limit: 256, printable_limit: 4_096)

    {:ok, diagnostic} =
      Diagnostic.new(
        target: state.target,
        stage: :execution,
        severity: :info,
        code: code,
        message: bounded_text(message, 4_096)
      )

    add_diagnostic(state, diagnostic)
  end

  defp add_diagnostic(state, diagnostic) do
    if length(state.diagnostics) < state.diagnostic_limit,
      do: %{state | diagnostics: [diagnostic | state.diagnostics]},
      else: state
  end

  defp bounded_optional(nil, _limit), do: nil
  defp bounded_optional(value, limit), do: bounded_text(value, limit)

  defp bounded_text(value, limit) when is_binary(value) do
    if byte_size(value) <= limit do
      value
    else
      truncate_utf8(value, limit - 3) <> "..."
    end
  end

  defp truncate_utf8(value, size) do
    candidate = binary_part(value, 0, min(byte_size(value), size))

    if String.valid?(candidate),
      do: candidate,
      else: truncate_utf8(candidate, byte_size(candidate) - 1)
  end

  defp malformed(state, reason),
    do: failure(state.target, :cargo_protocol, "Malformed Cargo #{reason} message", state)

  defp failure(target, code, message, state \\ nil) do
    stage = elem(Failure.stage_for(code), 1)

    diagnostics =
      if state,
        do: Enum.map(Enum.reverse(state.diagnostics), &%{&1 | stage: stage}),
        else: []

    {:error,
     Failure.new!(
       target: normalize_target(target),
       stage: stage,
       code: code,
       message: message,
       diagnostics: diagnostics
     )}
  end

  defp absolute_path?(value), do: safe_string?(value) and Path.type(value) == :absolute

  defp normalized_absolute_path?(value),
    do: absolute_path?(value) and Path.expand(value) == value

  defp absolute_path_list?(value),
    do:
      is_list(value) and proper_list?(value) and
        Enum.all?(value, &normalized_absolute_path?/1)

  defp optional_absolute_path(nil), do: :ok

  defp optional_absolute_path(value),
    do: if(normalized_absolute_path?(value), do: :ok, else: :error)

  defp optional_string(nil), do: :ok
  defp optional_string(value), do: if(safe_string?(value), do: :ok, else: :error)

  defp string_list?(value),
    do: is_list(value) and proper_list?(value) and Enum.all?(value, &safe_string?/1)

  defp env_list?(value) do
    is_list(value) and proper_list?(value) and
      Enum.all?(value, fn
        [name, item] -> safe_string?(name) and safe_string?(item)
        _ -> false
      end)
  end

  defp safe_string?(value),
    do: is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>)

  defp proper_list?(value), do: is_list(value) and :erlang.length(value) >= 0

  defp descendant?(path, root) do
    relative = Path.relative_to(path, root)
    relative != path and relative != ".." and not String.starts_with?(relative, "../")
  end

  defp normalize_target(target) when target in [:web, :desktop], do: target
  defp normalize_target(_target), do: nil
end
