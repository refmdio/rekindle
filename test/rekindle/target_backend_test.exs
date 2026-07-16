defmodule Rekindle.TargetBackendTest do
  use ExUnit.Case, async: true

  alias Rekindle.{ConfigError, TargetBackend}

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
  end

  test "publishes the exact behaviour callback surface" do
    assert TargetBackend.behaviour_info(:callbacks) |> Enum.sort() ==
             [backend_id: 0, backend_version: 0, finalize: 3, plan: 2, validate: 2]
  end
end
