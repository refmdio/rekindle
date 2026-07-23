defmodule Rekindle.InstallVerifyResultTest do
  use ExUnit.Case, async: true

  alias Rekindle.{Diagnostic, Failure, InstallVerifyResult}

  test "constructs and projects the exact verified result" do
    diagnostic = diagnostic(:warning)

    assert {:ok, result} =
             InstallVerifyResult.new(
               status: :verified,
               rekindle_version: "0.1.0",
               application_id: "sample_app",
               integration: :gpui,
               client_root: "clients/ui",
               targets: [:web, :desktop],
               checks: InstallVerifyResult.checks(),
               diagnostics: [diagnostic]
             )

    assert result.contract_version == 1

    assert result.checks == [
             %{name: :compatibility_manifest, status: :verified},
             %{name: :source_bundle, status: :verified},
             %{name: :client_layout, status: :verified},
             %{name: :cargo_graph, status: :verified},
             %{name: :phoenix_development, status: :verified},
             %{name: :phoenix_production, status: :verified},
             %{name: :ignore_rules, status: :verified},
             %{name: :generated_targets, status: :verified}
           ]

    assert InstallVerifyResult.to_map(result) == %{
             "contract_version" => 1,
             "status" => "verified",
             "rekindle_version" => "0.1.0",
             "application_id" => "sample_app",
             "integration" => "gpui",
             "client_root" => "clients/ui",
             "targets" => ["web", "desktop"],
             "checks" =>
               Enum.map(result.checks, fn check ->
                 %{"name" => Atom.to_string(check.name), "status" => "verified"}
               end),
             "diagnostics" => [Diagnostic.to_map(diagnostic)]
           }
  end

  test "accepts only canonical closed values" do
    base = valid_attributes()

    invalid = [
      Map.put(base, :contract_version, 2),
      Map.put(base, :status, :partial),
      Map.put(base, :rekindle_version, "01.0.0"),
      Map.put(base, :rekindle_version, String.duplicate("1", 129)),
      Map.put(base, :application_id, "SampleApp"),
      Map.put(base, :integration, :other),
      Map.put(base, :client_root, "../client"),
      Map.put(base, :client_root, "client//ui"),
      Map.put(base, :targets, []),
      Map.put(base, :targets, [:desktop, :web]),
      Map.put(base, :targets, [:web, :web]),
      Map.update!(base, :checks, &Enum.reverse/1),
      Map.update!(base, :checks, &tl/1),
      Map.put(base, :extra, true)
    ]

    for attributes <- invalid do
      assert {:error, %Failure{code: :contract_violation}} =
               InstallVerifyResult.new(attributes)
    end
  end

  test "diagnostics are bounded and cannot contain errors or targets" do
    base = valid_attributes()

    assert {:ok, _} =
             InstallVerifyResult.new(Map.put(base, :diagnostics, [diagnostic(:info)]))

    for diagnostics <- [
          [diagnostic(:error)],
          [diagnostic(:warning, :web)],
          List.duplicate(diagnostic(:info), 257),
          [:invalid]
        ] do
      assert {:error, %Failure{code: :contract_violation}} =
               InstallVerifyResult.new(Map.put(base, :diagnostics, diagnostics))
    end
  end

  defp valid_attributes do
    %{
      status: :verified,
      rekindle_version: "0.1.0-alpha.1+build.2",
      application_id: "sample_app",
      integration: :slint,
      client_root: "client",
      targets: [:desktop],
      checks: InstallVerifyResult.checks(),
      diagnostics: []
    }
  end

  defp diagnostic(severity, target \\ nil) do
    {:ok, diagnostic} =
      Diagnostic.new(
        target: target,
        stage: :compatibility,
        severity: severity,
        code: :install_check,
        message: "installation check"
      )

    diagnostic
  end
end
