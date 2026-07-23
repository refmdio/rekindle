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
           path: ["backend"],
           code: :invalid_value,
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
      {:error, List.duplicate(error(["backend"]), 257)}
    end

    def validate(_target, %{"case" => "improper_path"}) do
      {:error, [error(["backend" | :improper_tail])]}
    end

    def validate(_target, %{"case" => "oversized_path"}) do
      {:error, [error(List.duplicate("backend", 33))]}
    end

    def plan(_context, _options), do: :ok
    def finalize(_context, _options, _result), do: :ok

    defp error(path) do
      %Rekindle.ConfigError{
        path: path,
        code: :invalid_value,
        message: "invalid backend configuration"
      }
    end
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
    def backend_version, do: :persistent_term.get({__MODULE__, :version}, "1")
    def validate(_target, options), do: {:ok, options}
    def plan(_context, _options), do: :ok
    def finalize(_context, _options, _result), do: :ok
  end

  defmodule ConfigErrorsBackend do
    def backend_id, do: "config-errors.backend"
    def backend_version, do: "1"

    def validate(_target, %{"case" => kind}) do
      first = Rekindle.ConfigError.new(["a"], :invalid_type, "first")
      second = Rekindle.ConfigError.new(["b"], :conflict, "second")

      errors =
        case kind do
          "valid" -> [first, second]
          "empty" -> []
          "unsorted" -> [second, first]
          "duplicate" -> [first, first]
          "oversized" -> List.duplicate(first, 257)
        end

      {:error, errors}
    end

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
    assert {:error, [%ConfigError{path: ["backend", "module"]}]} =
             TargetBackend.admit("Elixir.DoesNotExist", :web, %{})
  end

  test "rejects missing callbacks and invalid identity" do
    assert {:error, [%ConfigError{message: message}]} = TargetBackend.admit(String, :web, %{})
    assert message =~ "missing callbacks"

    assert {:error, [%ConfigError{path: ["backend", "backend_id"]}]} =
             TargetBackend.admit(InvalidIdentityBackend, :web, %{})
  end

  test "rejects backend-normalized values outside CanonicalValue" do
    assert {:error, [%ConfigError{path: ["backend", "normalized_options"]}]} =
             TargetBackend.admit(InvalidOptionsBackend, :web, %{})

    assert {:error, [%ConfigError{path: ["backend", "options"]}]} =
             TargetBackend.admit(InvalidValidateResultBackend, :web, %{})

    assert {:error, [%ConfigError{path: ["backend", "options"]}]} =
             TargetBackend.admit(EmptyValidateErrorsBackend, :web, %{})

    assert {:error, [%ConfigError{path: ["backend", "options"]}]} =
             TargetBackend.admit(InvalidValidateErrorsBackend, :web, %{})
  end

  test "rejects improper and oversized backend error collections before traversal" do
    for shape <- ~w[improper_outer oversized_outer improper_path oversized_path] do
      assert {:error,
              [
                %ConfigError{
                  path: ["backend", "options"],
                  code: :invalid_value,
                  message: "extension configuration error contract violation"
                }
              ]} = TargetBackend.admit(ErrorShapeBackend, :web, %{"case" => shape})
    end
  end

  test "rejects improper canonical input and callback output lists" do
    for {value, path} <- [
          {[1 | :improper_tail], ["backend", "options"]},
          {%{"nested" => [1 | :improper_tail]}, ["backend", "options", "nested"]}
        ] do
      assert {:error,
              [
                %ConfigError{
                  path: ^path,
                  code: :invalid_type,
                  message: "list must be proper"
                }
              ]} = TargetBackend.admit(ValidBackend, :web, value)
    end

    for {shape, path} <- [
          {"improper", ["backend", "normalized_options"]},
          {"nested", ["backend", "normalized_options", "nested"]}
        ] do
      assert {:error,
              [
                %ConfigError{
                  path: ^path,
                  code: :invalid_type,
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
    on_exit(fn -> :persistent_term.erase({VersionBackend, :version}) end)

    for version <- [" ", "1", "v1.2.3+build", String.duplicate("~", 128)] do
      :persistent_term.put({VersionBackend, :version}, version)
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
      :persistent_term.put({VersionBackend, :version}, version)

      assert {:error, [%ConfigError{path: ["backend", "backend_version"]}]} =
               TargetBackend.admit(VersionBackend, :web)
    end
  end

  test "publishes the exact behaviour callback surface" do
    assert TargetBackend.behaviour_info(:callbacks) |> Enum.sort() ==
             [backend_id: 0, backend_version: 0, finalize: 3, plan: 2, validate: 2]
  end

  test "admits only sorted unique backend configuration errors" do
    first = ConfigError.new(["a"], :invalid_type, "first")
    second = ConfigError.new(["b"], :conflict, "second")

    assert {:error, [^first, ^second]} =
             TargetBackend.admit(ConfigErrorsBackend, :web, %{"case" => "valid"})

    for kind <- ~w[empty unsorted duplicate oversized] do
      assert {:error,
              [
                %ConfigError{
                  path: ["backend", "options"],
                  code: :invalid_value,
                  message: "extension configuration error contract violation"
                }
              ]} = TargetBackend.admit(ConfigErrorsBackend, :web, %{"case" => kind})
    end
  end

  test "converts backend configuration errors to the exact public failure" do
    errors = [
      ConfigError.new(["a"], :invalid_type, "wrong type"),
      ConfigError.new(["b"], :missing_key, "missing value")
    ]

    failure = TargetBackend.configuration_failure(:desktop, errors)

    assert failure.code == :config_invalid
    assert failure.stage == :configuration
    assert failure.message == "extension configuration is invalid"

    assert Enum.map(failure.diagnostics, & &1.code) ==
             [:backend_invalid_type, :backend_missing_key]

    assert Enum.map(failure.diagnostics, & &1.message) == ["wrong type", "missing value"]

    invalid = TargetBackend.configuration_failure(:desktop, Enum.reverse(errors))
    assert invalid.code == :contract_violation
    assert invalid.diagnostics == []
    assert invalid.message == "extension configuration error contract violation"
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

    assert {:error, %ConfigError{path: ["backend", "plan"]}} =
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

    assert {:error, %ConfigError{path: ["backend", "finalize"]}} =
             TargetBackend.validate_finalize_result({
               :ok,
               %{artifact | supplemental_diagnostics: ["not a diagnostic"]}
             })

    assert {:error, ^failure} = TargetBackend.validate_finalize_result({:error, failure})

    assert {:error, %ConfigError{path: ["backend", "finalize"]}} =
             TargetBackend.validate_finalize_result({:error, %{failure | contract_version: 2}})

    assert {:error, %ConfigError{}} =
             TargetBackend.validate_finalize_result({:ok, %{artifact | manifest: "../escape"}})

    assert {:error, %ConfigError{}} = TargetBackend.validate_finalize_result({:ok, %{}})
    assert {:error, %ConfigError{}} = TargetBackend.validate_finalize_result(:ok)
    assert {:error, %ConfigError{}} = TargetBackend.validate_finalize_result({:error, :invalid})

    assert {:error, %ConfigError{}} =
             TargetBackend.validate_finalize_result({:ok, %{artifact | contract_version: 2}})
  end

  test "sanitizes supplemental diagnostics and preserves their order" do
    first = diagnostic(:first_warning, "first")
    second = diagnostic(:second_warning, "second")

    artifact = %ExternalArtifact{
      manifest: "rekindle-web-manifest-v1.json",
      supplemental_diagnostics: [
        %{first | message: "first at /home/user/private.rs", rendered: "raw /tmp/output"},
        second
      ]
    }

    assert {:ok, sanitized} = TargetBackend.validate_finalize_result({:ok, artifact})

    assert Enum.map(sanitized.supplemental_diagnostics, & &1.code) ==
             [:first_warning, :second_warning]

    [sanitized_first, ^second] = sanitized.supplemental_diagnostics
    assert sanitized_first.message == "first at <redacted-path>"
    assert sanitized_first.rendered == "raw <redacted-path>"
    refute sanitized_first == first
  end

  test "rejects every invalid supplemental diagnostic field and location shape" do
    valid = diagnostic(:backend_warning, "valid")

    invalid_diagnostics = [
      %{valid | contract_version: 2},
      %{valid | target: :mobile},
      %{valid | stage: :unknown},
      %{valid | severity: :debug},
      %{valid | code: nil},
      %{valid | code: true},
      %{valid | code: "backend_warning"},
      %{valid | message: nil},
      %{valid | message: <<255>>},
      %{valid | message: "stacktrace:\n secret"},
      %{valid | message: String.duplicate("x", 65_537)},
      %{valid | rendered: <<255>>},
      %{valid | rendered: "** (RuntimeError) leaked"},
      %{valid | file: "/absolute/path"},
      %{valid | file: "../escape"},
      %{valid | file: <<255>>},
      %{valid | line: 1},
      %{valid | line: 0, file: "src/app.rs"},
      %{valid | line: 1.5, file: "src/app.rs"},
      %{valid | column: 1},
      %{valid | column: 0, line: 1, file: "src/app.rs"},
      %{valid | column: 1, file: "src/app.rs"}
    ]

    for invalid <- invalid_diagnostics do
      assert_finalize_diagnostic_error([invalid])
    end

    assert {:ok, located} =
             Diagnostic.new(
               target: :web,
               stage: :web_toolchain,
               severity: :warning,
               code: :located_warning,
               message: "located",
               file: "src/app.rs",
               line: 1,
               column: 2
             )

    assert {:ok, %ExternalArtifact{supplemental_diagnostics: [^located]}} =
             TargetBackend.validate_finalize_result({:ok, artifact([located])})
  end

  test "admits only a proper bounded supplemental diagnostic collection" do
    valid = diagnostic(:backend_warning, "valid")

    for invalid <- [nil, %{}, ["not a diagnostic"], [valid | :improper_tail]] do
      assert_finalize_diagnostic_error(invalid)
    end

    boundary = List.duplicate(valid, 1_024)

    assert {:ok, %ExternalArtifact{supplemental_diagnostics: ^boundary}} =
             TargetBackend.validate_finalize_result({:ok, artifact(boundary)})

    assert_finalize_diagnostic_error(List.duplicate(valid, 1_025))
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

  defp diagnostic(code, message) do
    {:ok, diagnostic} =
      Diagnostic.new(
        target: :web,
        stage: :web_toolchain,
        severity: :warning,
        code: code,
        message: message
      )

    diagnostic
  end

  defp artifact(diagnostics) do
    %ExternalArtifact{
      manifest: "rekindle-web-manifest-v1.json",
      supplemental_diagnostics: diagnostics
    }
  end

  defp assert_finalize_diagnostic_error(diagnostics) do
    assert {:error, %ConfigError{path: ["backend", "finalize"]}} =
             TargetBackend.validate_finalize_result({:ok, artifact(diagnostics)})
  end
end
