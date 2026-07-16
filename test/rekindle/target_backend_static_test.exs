defmodule Rekindle.TargetBackendStaticTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  alias Rekindle.{ExecutionResult, ExternalArtifact, Failure, TargetBackend}

  test "publishes exact closed public value types" do
    assert Failure
           |> type_entry(:code)
           |> literal_atoms()
           |> Enum.sort() == Enum.sort(Failure.codes())

    assert compact_type(ExternalArtifact, :t) ==
             "t()::%Rekindle.ExternalArtifact{contract_version:1,manifest:String.t(),supplemental_diagnostics:[Rekindle.Diagnostic.t()]}"

    assert compact_type(ExecutionResult, :outcome) ==
             "outcome():::exited|:signaled|:spawn_failed"

    assert compact_type(ExecutionResult, :cleanup) ==
             "cleanup():::confirmed|:uncertain"

    assert compact_type(ExecutionResult, :discarded_bytes) ==
             "discarded_bytes()::%{stdout:non_neg_integer(),stderr:non_neg_integer()}"

    assert compact_type(ExecutionResult, :t) ==
             "t()::%Rekindle.ExecutionResult{build_key:String.t(),cleanup:cleanup(),contract_version:1,discarded_bytes:discarded_bytes(),duration_ms:non_neg_integer(),exit_code:integer()|nil,outcome:outcome(),signal:non_neg_integer()|nil,stderr_tail:binary(),stdout_tail:binary()}"
  end

  test "publishes the exact five callback typespecs" do
    assert callback_surface(TargetBackend) == %{
             {:backend_id, 0} => "backend_id() :: String.t()",
             {:backend_version, 0} => "backend_version() :: String.t()",
             {:validate, 2} =>
               "validate(Rekindle.target(), Rekindle.CanonicalValue.t()) ::\n  {:ok, normalized_options :: Rekindle.CanonicalValue.t()} | {:error, [Rekindle.ConfigError.t()]}",
             {:plan, 2} =>
               "plan(Rekindle.BackendContext.t(), Rekindle.CanonicalValue.t()) ::\n  {:ok, Rekindle.ExternalPlan.t()} | {:error, Rekindle.Failure.t()}",
             {:finalize, 3} =>
               "finalize(Rekindle.BackendContext.t(), Rekindle.CanonicalValue.t(), Rekindle.ExecutionResult.t()) ::\n  {:ok, Rekindle.ExternalArtifact.t()} | {:error, Rekindle.Failure.t()}"
           }
  end

  test "Dialyzer admits valid target implementations and rejects signature drift" do
    root = temporary_root()
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)
    plt = ensure_core_plt!()

    for module <- [ValidWebBackend, ValidDesktopBackend] do
      beam = compile_fixture!(root, module, backend_source(module))
      {output, status} = dialyze(plt, beam)
      assert status == 0, output
    end

    invalid = [
      {WrongBackendIdReturn,
       [backend_id_return: "integer()", backend_id_body: "def backend_id, do: 1"],
       "backend_id/0"},
      {WrongBackendVersionReturn,
       [
         backend_version_return: "atom()",
         backend_version_body: "def backend_version, do: :invalid"
       ], "backend_version/0"},
      {WrongValidateArgument, [validate_spec: "String.t(), Rekindle.CanonicalValue.t()"],
       "validate/2"},
      {WrongPlanOrder, [plan_spec: "Rekindle.CanonicalValue.t(), Rekindle.BackendContext.t()"],
       "plan/2"},
      {WrongValidateUnion,
       [
         validate_return: ":ok | {:error, [Rekindle.ConfigError.t()]}",
         validate_body: "def validate(_target, _options), do: :ok"
       ], "validate/2"},
      {WrongPlanUnion,
       [
         plan_return: "{:ok, String.t()} | {:error, Rekindle.Failure.t()}",
         plan_body: ~S|def plan(_context, _options), do: {:ok, "invalid"}|
       ], "plan/2"},
      {WrongFinalizeUnion,
       [
         finalize_return: "{:ok, Rekindle.ExternalPlan.t()} | {:error, Rekindle.Failure.t()}",
         finalize_body: "def finalize(_context, _options, _result), do: {:ok, plan()}"
       ], "finalize/3"}
    ]

    for {module, overrides, callback} <- invalid do
      beam = compile_fixture!(root, module, backend_source(module, overrides))
      assert {output, 2} = dialyze(plt, beam)
      assert output =~ callback
      assert output =~ "callback of the 'Elixir.Rekindle.TargetBackend' behaviour"
    end
  end

  test "Dialyzer admits exact public values and rejects closed-type drift" do
    root = temporary_root()
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)
    plt = ensure_core_plt!()

    valid = compile_fixture!(root, ValidPublicValues, valid_public_values_source())
    {output, status} = dialyze(plt, valid, ["-Wmissing_return"])
    assert status == 0, output

    invalid =
      compile_fixture!(root, InvalidPublicValues, invalid_public_values_source())

    {output, status} = dialyze(plt, invalid, ["-Wmissing_return"])
    assert status == 2, "invalid public values were accepted:\n#{output}"

    for function <- [
          "failure_code/0",
          "supplemental_diagnostic/0",
          "execution_outcome/0",
          "execution_cleanup/0",
          "execution_discard/0"
        ] do
      assert output =~ function
    end
  end

  defp backend_source(module, overrides \\ []) do
    backend_id_return = Keyword.get(overrides, :backend_id_return, "String.t()")

    backend_id_body =
      Keyword.get(overrides, :backend_id_body, ~S|def backend_id, do: "static.fixture"|)

    backend_version_return = Keyword.get(overrides, :backend_version_return, "String.t()")

    backend_version_body =
      Keyword.get(overrides, :backend_version_body, ~S|def backend_version, do: "1"|)

    validate_spec =
      Keyword.get(overrides, :validate_spec, "Rekindle.target(), Rekindle.CanonicalValue.t()")

    validate_return =
      Keyword.get(
        overrides,
        :validate_return,
        "{:ok, Rekindle.CanonicalValue.t()} | {:error, [Rekindle.ConfigError.t()]}"
      )

    plan_spec =
      Keyword.get(
        overrides,
        :plan_spec,
        "Rekindle.BackendContext.t(), Rekindle.CanonicalValue.t()"
      )

    plan_return =
      Keyword.get(
        overrides,
        :plan_return,
        "{:ok, Rekindle.ExternalPlan.t()} | {:error, Rekindle.Failure.t()}"
      )

    finalize_return =
      Keyword.get(
        overrides,
        :finalize_return,
        "{:ok, Rekindle.ExternalArtifact.t()} | {:error, Rekindle.Failure.t()}"
      )

    validate_body =
      Keyword.get(
        overrides,
        :validate_body,
        "def validate(target, options) when target in [:web, :desktop], do: {:ok, options}"
      )

    plan_body =
      Keyword.get(overrides, :plan_body, "def plan(_context, _options), do: {:ok, plan()}")

    finalize_body =
      Keyword.get(
        overrides,
        :finalize_body,
        "def finalize(_context, _options, _result), do: {:ok, artifact()}"
      )

    """
    defmodule #{inspect(module)} do
      @behaviour Rekindle.TargetBackend

      @spec backend_id() :: #{backend_id_return}
      #{backend_id_body}

      @spec backend_version() :: #{backend_version_return}
      #{backend_version_body}

      @spec validate(#{validate_spec}) :: #{validate_return}
      #{validate_body}

      @spec plan(#{plan_spec}) :: #{plan_return}
      #{plan_body}

      @spec finalize(Rekindle.BackendContext.t(), Rekindle.CanonicalValue.t(), Rekindle.ExecutionResult.t()) :: #{finalize_return}
      #{finalize_body}

      defp plan do
        %Rekindle.ExternalPlan{
          executable: "/bin/true",
          argv: [],
          cwd: %{root: :staging, path: "."},
          env_mode: :replace,
          env_set: [],
          diagnostic_mode: :opaque,
          timeout_ms: 1,
          expected_manifest: "manifest.json"
        }
      end

      defp artifact do
        %Rekindle.ExternalArtifact{
          manifest: "manifest.json",
          supplemental_diagnostics: []
        }
      end
    end
    """
  end

  defp valid_public_values_source do
    """
    defmodule #{inspect(ValidPublicValues)} do
      @spec failure_code() :: Rekindle.Failure.code()
      def failure_code, do: :config_invalid

      @spec artifact() :: Rekindle.ExternalArtifact.t()
      def artifact do
        #{external_artifact("[diagnostic()]")}
      end

      @spec execution_result() :: Rekindle.ExecutionResult.t()
      def execution_result do
        #{execution_result()}
      end

      @spec diagnostic() :: Rekindle.Diagnostic.t()
      defp diagnostic do
        %Rekindle.Diagnostic{
          target: :web,
          stage: :web_toolchain,
          severity: :warning,
          code: :fixture,
          message: "fixture"
        }
      end
    end
    """
  end

  defp invalid_public_values_source do
    """
    defmodule #{inspect(InvalidPublicValues)} do
      @spec failure_code() :: Rekindle.Failure.code()
      def failure_code, do: "not a failure code"

      @spec supplemental_diagnostic() :: Rekindle.ExternalArtifact.t()
      def supplemental_diagnostic do
        #{external_artifact("[\"not a diagnostic\"]")}
      end

      @spec execution_outcome() :: Rekindle.ExecutionResult.t()
      def execution_outcome do
        #{execution_result(outcome: ":cancelled")}
      end

      @spec execution_cleanup() :: Rekindle.ExecutionResult.t()
      def execution_cleanup do
        #{execution_result(cleanup: "%{status: :confirmed}")}
      end

      @spec execution_discard() :: Rekindle.ExecutionResult.t()
      def execution_discard do
        #{execution_result(discarded_bytes: "0")}
      end
    end
    """
  end

  defp external_artifact(diagnostics) do
    """
    %Rekindle.ExternalArtifact{
      manifest: "manifest.json",
      supplemental_diagnostics: #{diagnostics}
    }
    """
  end

  defp execution_result(overrides \\ []) do
    outcome = Keyword.get(overrides, :outcome, ":exited")
    cleanup = Keyword.get(overrides, :cleanup, ":confirmed")
    discarded_bytes = Keyword.get(overrides, :discarded_bytes, "%{stdout: 0, stderr: 0}")

    """
    %Rekindle.ExecutionResult{
      build_key: "build-key",
      outcome: #{outcome},
      exit_code: 0,
      signal: nil,
      duration_ms: 1,
      stdout_tail: <<>>,
      stderr_tail: <<>>,
      discarded_bytes: #{discarded_bytes},
      cleanup: #{cleanup}
    }
    """
  end

  defp compile_fixture!(root, module, source) do
    {output, status, beam} = compile_source(root, module, source)
    assert status == 0, output
    beam
  end

  defp compile_source(root, module, source, extra_arguments \\ []) do
    source_path =
      Path.join(root, "#{module |> Module.split() |> List.last() |> Macro.underscore()}.ex")

    beam_root = Path.join(root, Atom.to_string(module))
    File.mkdir_p!(beam_root)
    File.write!(source_path, source)
    project_ebin = TargetBackend |> :code.which() |> to_string() |> Path.dirname()

    arguments =
      ["-pa", project_ebin, "--ignore-module-conflict"] ++
        extra_arguments ++ ["-o", beam_root, source_path]

    {output, status} = System.cmd(elixirc!(), arguments, stderr_to_stdout: true)

    {output, status, Path.join(beam_root, "Elixir.#{inspect(module)}.beam")}
  end

  defp dialyze(plt, fixture_beam, extra_arguments \\ []) do
    arguments =
      [
        "-Wno_unknown",
        "-Wno_match",
        "--plt",
        plt,
        "--no_check_plt"
      ] ++ extra_arguments ++ contract_beams() ++ [fixture_beam]

    System.cmd(dialyzer!(), arguments,
      env: [{"ERL_LIBS", elixir_lib_root()}],
      stderr_to_stdout: true
    )
  end

  defp contract_beams do
    [
      Rekindle,
      TargetBackend,
      Rekindle.CanonicalValue,
      Rekindle.ConfigError,
      Rekindle.BackendContext,
      Rekindle.ExternalPlan,
      Rekindle.Failure,
      Rekindle.ExecutionResult,
      Rekindle.ExternalArtifact,
      Rekindle.Diagnostic,
      Rekindle.QualifiedPath,
      Rekindle.Redactor
    ]
    |> Enum.map(fn module -> module |> :code.which() |> to_string() end)
  end

  defp ensure_core_plt! do
    cache =
      Path.join([
        File.cwd!(),
        "_build",
        "test",
        "target_backend_static",
        "otp-#{System.otp_release()}-elixir-#{System.version()}.plt"
      ])

    unless File.regular?(cache) do
      File.mkdir_p!(Path.dirname(cache))
      temporary = cache <> ".#{System.unique_integer([:positive])}.tmp"

      {output, status} =
        System.cmd(
          dialyzer!(),
          [
            "-Wno_unknown",
            "--build_plt",
            "--apps",
            "erts",
            "kernel",
            "stdlib",
            "crypto",
            "compiler",
            "syntax_tools",
            "parsetools",
            "elixir",
            "--output_plt",
            temporary
          ],
          env: [{"ERL_LIBS", elixir_lib_root()}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      File.rename!(temporary, cache)
    end

    cache
  end

  defp temporary_root do
    Path.join(
      System.tmp_dir!(),
      "rekindle-target-backend-static-#{System.unique_integer([:positive])}"
    )
  end

  defp callback_surface(module) do
    assert {:ok, callbacks} = Code.Typespec.fetch_callbacks(module)

    Map.new(callbacks, fn {{name, arity}, [spec]} ->
      {{name, arity}, name |> Code.Typespec.spec_to_quoted(spec) |> Macro.to_string()}
    end)
  end

  defp compact_type(module, name) do
    module
    |> type_entry(name)
    |> Code.Typespec.type_to_quoted()
    |> Macro.to_string()
    |> String.replace(~r/\s+/, "")
  end

  defp type_entry(module, name) when is_atom(module) do
    assert {:ok, types} = Code.Typespec.fetch_types(module)

    assert {_visibility, {^name, _type, []} = entry} =
             Enum.find(types, fn
               {_visibility, {^name, _type, []}} -> true
               _other -> false
             end)

    entry
  end

  defp literal_atoms({_name, type, []}), do: literal_atoms(type)
  defp literal_atoms({:atom, _line, value}), do: [value]

  defp literal_atoms({:type, _line, :union, members}),
    do: Enum.flat_map(members, &literal_atoms/1)

  defp literal_atoms(other), do: flunk("expected a literal atom union, got: #{inspect(other)}")

  defp elixir_lib_root,
    do: :elixir |> :code.lib_dir() |> to_string() |> Path.dirname()

  defp dialyzer!, do: System.find_executable("dialyzer") || flunk("dialyzer is unavailable")
  defp elixirc!, do: System.find_executable("elixirc") || flunk("elixirc is unavailable")
end
