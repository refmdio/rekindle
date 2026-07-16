defmodule Rekindle.TargetBackendStaticTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  alias Rekindle.TargetBackend

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

  defp dialyze(plt, fixture_beam) do
    arguments =
      [
        "-Wno_unknown",
        "-Wno_match",
        "--plt",
        plt,
        "--no_check_plt"
      ] ++ contract_beams() ++ [fixture_beam]

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
      Rekindle.QualifiedPath
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

  defp elixir_lib_root,
    do: :elixir |> :code.lib_dir() |> to_string() |> Path.dirname()

  defp dialyzer!, do: System.find_executable("dialyzer") || flunk("dialyzer is unavailable")
  defp elixirc!, do: System.find_executable("elixirc") || flunk("elixirc is unavailable")
end
