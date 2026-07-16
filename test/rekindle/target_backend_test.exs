defmodule Rekindle.TargetBackendTest do
  use ExUnit.Case, async: true

  alias Rekindle.{ConfigError, Diagnostic, TargetBackend}
  alias Rekindle.{ExternalArtifact, ExternalPlan, Failure}

  defmodule ValidBackend do
    @behaviour TargetBackend

    @impl true
    def backend_id, do: "example.backend"

    @impl true
    def backend_version, do: "1.2.3"

    @impl true
    def validate(target, options), do: {:ok, Map.put(options, "target", Atom.to_string(target))}

    @impl true
    def plan(_context, _options), do: {:error, nil}

    @impl true
    def finalize(_context, _options, _result), do: {:error, nil}
  end

  defmodule InvalidIdentityBackend do
    def backend_id, do: "INVALID"
    def backend_version, do: "1"
    def validate(_target, options), do: {:ok, options}
    def plan(_context, _options), do: {:error, nil}
    def finalize(_context, _options, _result), do: {:error, nil}
  end

  defmodule InvalidOptionsBackend do
    def backend_id, do: "invalid.options"
    def backend_version, do: "1"
    def validate(_target, _options), do: {:ok, %{atom: :value}}
    def plan(_context, _options), do: {:error, nil}
    def finalize(_context, _options, _result), do: {:error, nil}
  end

  defmodule InvalidValidateResultBackend do
    def backend_id, do: "invalid.validate-result"
    def backend_version, do: "1"
    def validate(_target, _options), do: :ok
    def plan(_context, _options), do: :ok
    def finalize(_context, _options, _result), do: :ok
  end

  defmodule EmptyValidateErrorsBackend do
    def backend_id, do: "invalid.empty-errors"
    def backend_version, do: "1"
    def validate(_target, _options), do: {:error, []}
    def plan(_context, _options), do: :ok
    def finalize(_context, _options, _result), do: :ok
  end

  defmodule InvalidValidateErrorsBackend do
    def backend_id, do: "invalid.malformed-errors"
    def backend_version, do: "1"

    def validate(_target, _options) do
      {:error,
       [
         %Rekindle.ConfigError{
           contract_version: 2,
           path: [:backend],
           code: :config_invalid,
           message: "invalid"
         }
       ]}
    end

    def plan(_context, _options), do: :ok
    def finalize(_context, _options, _result), do: :ok
  end

  defmodule ErrorShapeBackend do
    def backend_id, do: "invalid.error-shape"
    def backend_version, do: "1"

    def validate(_target, %{"case" => "improper_outer"}) do
      {:error, [error([:backend]) | :improper_tail]}
    end

    def validate(_target, %{"case" => "oversized_outer"}) do
      {:error, List.duplicate(error([:backend]), 129)}
    end

    def validate(_target, %{"case" => "improper_path"}) do
      {:error, [error([:backend | :improper_tail])]}
    end

    def validate(_target, %{"case" => "oversized_path"}) do
      {:error, [error(List.duplicate(:backend, 129))]}
    end

    def plan(_context, _options), do: :ok
    def finalize(_context, _options, _result), do: :ok

    defp error(path),
      do: Rekindle.ConfigError.new(path, :config_invalid, "invalid backend configuration")
  end

  defmodule CanonicalOutputShapeBackend do
    def backend_id, do: "invalid.canonical-output-shape"
    def backend_version, do: "1"
    def validate(_target, %{"case" => "improper"}), do: {:ok, [1 | :improper_tail]}
    def validate(_target, %{"case" => "nested"}), do: {:ok, %{"nested" => [1 | :bad]}}
    def validate(_target, %{"case" => "oversized"}), do: {:ok, List.duplicate(nil, 129)}
    def plan(_context, _options), do: :ok
    def finalize(_context, _options, _result), do: :ok
  end

  defmodule VersionBackend do
    def backend_id, do: "version.backend"
    def backend_version, do: Process.get({__MODULE__, :version}, "1")
    def validate(_target, options), do: {:ok, options}
    def plan(_context, _options), do: :ok
    def finalize(_context, _options, _result), do: :ok
  end

  test "admits an existing conforming module and normalized options" do
    assert {:ok, admission} = TargetBackend.admit(ValidBackend, :web, %{"answer" => 42})
    assert admission.module == ValidBackend
    assert admission.backend_id == "example.backend"
    assert admission.backend_version == "1.2.3"
    assert admission.options == %{"answer" => 42, "target" => "web"}
    assert admission.options_digest =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "defaults options to an empty map" do
    assert {:ok, %{options: %{"target" => "desktop"}}} =
             TargetBackend.admit(ValidBackend, :desktop)
  end

  test "rejects an unloaded module without converting text to an atom" do
    assert {:error, [%ConfigError{path: [:backend, :module]}]} =
             TargetBackend.admit("Elixir.DoesNotExist", :web, %{})
  end

  test "rejects missing callbacks and invalid identity" do
    assert {:error, [%ConfigError{message: message}]} = TargetBackend.admit(String, :web, %{})
    assert message =~ "missing callbacks"

    assert {:error, [%ConfigError{path: [:backend, :backend_id]}]} =
             TargetBackend.admit(InvalidIdentityBackend, :web, %{})
  end

  test "rejects backend-normalized values outside CanonicalValue" do
    assert {:error, [%ConfigError{path: [:backend, :normalized_options]}]} =
             TargetBackend.admit(InvalidOptionsBackend, :web, %{})

    assert {:error, [%ConfigError{path: [:backend, :options]}]} =
             TargetBackend.admit(InvalidValidateResultBackend, :web, %{})

    assert {:error, [%ConfigError{path: [:backend, :options]}]} =
             TargetBackend.admit(EmptyValidateErrorsBackend, :web, %{})

    assert {:error, [%ConfigError{path: [:backend, :options]}]} =
             TargetBackend.admit(InvalidValidateErrorsBackend, :web, %{})
  end

  test "rejects improper and oversized backend error collections before traversal" do
    for shape <- ~w[improper_outer oversized_outer improper_path oversized_path] do
      assert {:error,
              [
                %ConfigError{
                  path: [:backend, :options],
                  code: :config_invalid,
                  message: "validate/2 returned invalid errors"
                }
              ]} = TargetBackend.admit(ErrorShapeBackend, :web, %{"case" => shape})
    end
  end

  test "rejects improper canonical input and callback output lists" do
    for {value, path} <- [
          {[1 | :improper_tail], [:backend, :options]},
          {%{"nested" => [1 | :improper_tail]}, [:backend, :options, "nested"]}
        ] do
      assert {:error,
              [
                %ConfigError{
                  path: ^path,
                  code: :unsupported_value,
                  message: "list must be proper"
                }
              ]} = TargetBackend.admit(ValidBackend, :web, value)
    end

    for {shape, path} <- [
          {"improper", [:backend, :normalized_options]},
          {"nested", [:backend, :normalized_options, "nested"]}
        ] do
      assert {:error,
              [
                %ConfigError{
                  path: ^path,
                  code: :unsupported_value,
                  message: "list must be proper"
                }
              ]} =
               TargetBackend.admit(CanonicalOutputShapeBackend, :web, %{"case" => shape})
    end

    assert {:ok, %{options: options}} =
             TargetBackend.admit(CanonicalOutputShapeBackend, :web, %{"case" => "oversized"})

    assert length(options) == 129
  end

  test "admits only bounded control-free ASCII backend versions" do
    on_exit(fn -> Process.delete({VersionBackend, :version}) end)

    for version <- [" ", "1", "v1.2.3+build", String.duplicate("~", 128)] do
      Process.put({VersionBackend, :version}, version)
      assert {:ok, %{backend_version: ^version}} = TargetBackend.admit(VersionBackend, :web)
    end

    for version <- [
          "",
          String.duplicate("a", 129),
          "é",
          <<0>>,
          "1\n2",
          "1\r2",
          <<0x1F>>,
          <<0x7F>>
        ] do
      Process.put({VersionBackend, :version}, version)

      assert {:error, [%ConfigError{path: [:backend, :backend_version]}]} =
               TargetBackend.admit(VersionBackend, :web)
    end
  end

  test "publishes the exact behaviour callback surface" do
    assert TargetBackend.behaviour_info(:callbacks) |> Enum.sort() ==
             [backend_id: 0, backend_version: 0, finalize: 3, plan: 2, validate: 2]
  end

  test "validates the exact plan and finalize return unions" do
    plan = %ExternalPlan{
      executable: "/usr/bin/cargo",
      argv: ["build"],
      cwd: %{root: :client, path: "."},
      env_mode: :replace,
      env_set: [%{name: "PATH", value: "/usr/bin", secret: false}],
      diagnostic_mode: :cargo_json,
      timeout_ms: 1_000,
      expected_manifest: "rekindle-web-manifest-v1.json"
    }

    assert {:ok, ^plan} = TargetBackend.validate_plan_result({:ok, plan})

    for root <- [:project, :client, :staging] do
      assert {:ok, _} =
               TargetBackend.validate_plan_result({:ok, %{plan | cwd: %{root: root, path: "."}}})
    end

    assert {:error, %ConfigError{}} =
             TargetBackend.validate_plan_result({:ok, %{plan | env_mode: :inherit}})

    assert {:error, %ConfigError{}} = TargetBackend.validate_plan_result({:ok, %{}})
    assert {:error, %ConfigError{}} = TargetBackend.validate_plan_result(:ok)
    assert {:error, %ConfigError{}} = TargetBackend.validate_plan_result({:error, :invalid})

    assert {:error, %ConfigError{}} =
             TargetBackend.validate_plan_result({:ok, %{plan | contract_version: 2}})

    for manifest <- [
          "",
          ".",
          "/absolute.json",
          "../escape.json",
          "a/../escape.json",
          "a\\b",
          "a\0b"
        ] do
      assert {:error, %ConfigError{}} =
               TargetBackend.validate_plan_result({:ok, %{plan | expected_manifest: manifest}})
    end

    for cwd <- [
          %{root: :client, path: ""},
          %{root: :client, path: "../escape"},
          %{root: :client, path: "/absolute"},
          %{root: :unknown, path: "."},
          %{root: :client, path: ".", extra: true}
        ] do
      assert {:error, %ConfigError{}} =
               TargetBackend.validate_plan_result({:ok, %{plan | cwd: cwd}})
    end

    invalid_utf8 = <<255>>
    oversized = String.duplicate("x", 1_048_577)

    for argv <- [["ok\0bad"], [invalid_utf8], [oversized], List.duplicate("xx", 524_289)] do
      assert {:error, %ConfigError{}} =
               TargetBackend.validate_plan_result({:ok, %{plan | argv: argv}})
    end

    assert {:error, %ConfigError{}} =
             TargetBackend.validate_plan_result({:ok, %{plan | argv: ["x" | "tail"]}})

    for env_set <- [
          [%{name: "A", value: "bad\0value", secret: false}],
          [%{name: "A", value: invalid_utf8, secret: false}],
          [%{name: "A", value: oversized, secret: false}],
          [%{name: "B", value: "b", secret: false}, %{name: "A", value: "a", secret: false}],
          [%{name: "A", value: "a", secret: false}, %{name: "A", value: "b", secret: true}],
          [%{name: "A", value: "a", secret: false, extra: true}]
        ] do
      assert {:error, %ConfigError{}} =
               TargetBackend.validate_plan_result({:ok, %{plan | env_set: env_set}})
    end

    assert {:error, %ConfigError{}} =
             TargetBackend.validate_plan_result({
               :ok,
               %{plan | env_set: [%{name: "A", value: "a", secret: false} | "tail"]}
             })

    failure =
      Failure.new!(target: :web, stage: :internal, code: :internal, message: "backend failed")

    assert {:error, ^failure} = TargetBackend.validate_plan_result({:error, failure})

    assert {:error, %ConfigError{path: [:backend, :plan]}} =
             TargetBackend.validate_plan_result({:error, %{failure | contract_version: 2}})

    artifact = %ExternalArtifact{
      manifest: "rekindle-web-manifest-v1.json",
      supplemental_diagnostics: []
    }

    assert {:ok, ^artifact} = TargetBackend.validate_finalize_result({:ok, artifact})

    assert {:ok, diagnostic} =
             Diagnostic.new(
               target: :web,
               stage: :web_toolchain,
               severity: :warning,
               code: :backend_warning,
               message: "backend warning"
             )

    artifact_with_diagnostic = %{artifact | supplemental_diagnostics: [diagnostic]}

    assert {:ok, ^artifact_with_diagnostic} =
             TargetBackend.validate_finalize_result({:ok, artifact_with_diagnostic})

    assert {:error, %ConfigError{path: [:backend, :finalize]}} =
             TargetBackend.validate_finalize_result({
               :ok,
               %{artifact | supplemental_diagnostics: ["not a diagnostic"]}
             })

    assert {:error, ^failure} = TargetBackend.validate_finalize_result({:error, failure})

    assert {:error, %ConfigError{path: [:backend, :finalize]}} =
             TargetBackend.validate_finalize_result({:error, %{failure | contract_version: 2}})

    assert {:error, %ConfigError{}} =
             TargetBackend.validate_finalize_result({:ok, %{artifact | manifest: "../escape"}})

    assert {:error, %ConfigError{}} = TargetBackend.validate_finalize_result({:ok, %{}})
    assert {:error, %ConfigError{}} = TargetBackend.validate_finalize_result(:ok)
    assert {:error, %ConfigError{}} = TargetBackend.validate_finalize_result({:error, :invalid})

    assert {:error, %ConfigError{}} =
             TargetBackend.validate_finalize_result({:ok, %{artifact | contract_version: 2}})
  end

  test "negative compile fixtures report wrong callback arities and reject unknown struct fields" do
    module = "WrongArityBackend#{System.unique_integer([:positive])}"

    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{module} do
          @behaviour Rekindle.TargetBackend
          def backend_id, do: "wrong-arity"
          def backend_version, do: "1"
          def validate(_target), do: {:ok, %{}}
          def plan(_context), do: :invalid
          def finalize(_context, _options), do: :invalid
        end
        """)
      end)

    assert warning =~ "required by behaviour Rekindle.TargetBackend"
    assert warning =~ "validate/2"
    assert warning =~ "plan/2"
    assert warning =~ "finalize/3"

    for structure <- [
          "Rekindle.BackendContext",
          "Rekindle.ExternalPlan",
          "Rekindle.ExecutionResult",
          "Rekindle.ExternalArtifact"
        ] do
      assert_raise KeyError, fn ->
        Code.compile_string("%#{structure}{unknown_field: true}")
      end
    end
  end
end
