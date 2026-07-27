defmodule Rekindle.Doctor do
  @moduledoc false

  alias Rekindle.Cargo
  alias Rekindle.Cargo.Metadata
  alias Rekindle.Config
  alias Rekindle.Integration
  alias Rekindle.Toolchain
  alias Rekindle.Toolchain.Check

  @spec run(atom(), keyword()) :: {:ok, [Check.t()]} | {:error, [Check.t()]}
  def run(otp_app, options \\ []) do
    case Config.load(otp_app, options) do
      {:ok, project} -> inspect_project(project, options)
      {:error, error} -> finish([failed(:configuration, Exception.message(error))])
    end
  end

  defp inspect_project(project, options) do
    options = Keyword.put(options, :cd, project.client_root)
    targets = project.targets |> Map.keys() |> Enum.sort()

    checks =
      [passed(:configuration, "Rekindle configuration is valid")]
      |> check_cargo_readiness(options)
      |> check_executable(:rustup, Toolchain.rustup_path(options))
      |> check_rust_targets(targets, options)
      |> check_wasm_bindgen(targets, options)
      |> check_cargo(project, targets, options)

    finish(checks)
  end

  defp check_cargo_readiness(checks, options) do
    check =
      case Toolchain.cargo_version(options) do
        {:ok, version} ->
          passed(:cargo, "cargo #{version} found at #{Toolchain.cargo_path(options)}")

        {:error, error} ->
          failed(:cargo, Exception.message(error))
      end

    checks ++ [check]
  end

  defp check_executable(checks, name, path) do
    check =
      if Path.type(path) == :absolute and File.regular?(path) do
        passed(name, "#{name} found at #{path}")
      else
        failed(name, "#{name} executable was not found")
      end

    checks ++ [check]
  end

  defp check_rust_targets(checks, targets, options) do
    case Toolchain.installed_rust_targets(options) do
      {:ok, installed} ->
        checks ++
          Enum.map(targets, fn target ->
            case Toolchain.target(target, options) do
              {:ok, triple} ->
                if triple in installed do
                  passed(:"rust_#{target}", "#{triple} is installed")
                else
                  failed(
                    :"rust_#{target}",
                    "#{triple} is missing; run mix rekindle.setup #{target}"
                  )
                end

              {:error, error} ->
                failed(:"rust_#{target}", Exception.message(error))
            end
          end)

      {:error, error} ->
        checks ++ [failed(:rust_targets, Exception.message(error))]
    end
  end

  defp check_wasm_bindgen(checks, [:desktop], _options), do: checks

  defp check_wasm_bindgen(checks, _targets, options) do
    version = Toolchain.wasm_bindgen_version()

    check =
      case Toolchain.resolve_wasm_bindgen(version, options) do
        {:ok, path} ->
          passed(:wasm_bindgen, "wasm-bindgen #{version} found at #{path}")

        {:error, error} ->
          failed(
            :wasm_bindgen,
            "#{Exception.message(error)}; run mix rekindle.setup web"
          )
      end

    checks ++ [check]
  end

  defp check_cargo(checks, project, targets, options) do
    case Metadata.load(project, Keyword.put(options, :locked, true)) do
      {:ok, metadata} ->
        checks ++
          [passed(:cargo_metadata, "Cargo metadata is valid")] ++
          Enum.flat_map(targets, &target_checks(metadata, project, &1))

      {:error, error} ->
        checks ++ [failed(:cargo_metadata, Exception.message(error))]
    end
  end

  defp target_checks(metadata, project, target_name) do
    target = Map.fetch!(project.targets, target_name)

    case Cargo.resolve(metadata, project, target) do
      {:ok, package, binary} ->
        dependency = Integration.dependency(project.integration)

        dependency_check =
          if dependency in package.dependencies do
            passed(
              :"#{target_name}_integration",
              "#{package.name} directly depends on #{dependency}"
            )
          else
            failed(
              :"#{target_name}_integration",
              "#{package.name} must directly depend on #{dependency}"
            )
          end

        [
          passed(:"#{target_name}_binary", "Cargo resolves #{package.name}:#{binary}"),
          dependency_check
        ]

      {:error, error} ->
        [failed(:"#{target_name}_binary", Exception.message(error))]
    end
  end

  defp finish(checks) do
    if Enum.any?(checks, &(&1.status == :error)),
      do: {:error, checks},
      else: {:ok, checks}
  end

  defp passed(name, message), do: %Check{name: name, status: :ok, message: message}
  defp failed(name, message), do: %Check{name: name, status: :error, message: message}
end
