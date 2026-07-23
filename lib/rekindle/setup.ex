defmodule Rekindle.Setup do
  @moduledoc false

  alias Rekindle.Config
  alias Rekindle.Toolchain
  alias Rekindle.Toolchain.Check

  @rust_targets %{web: "wasm32-unknown-unknown", desktop: "x86_64-unknown-linux-gnu"}

  @spec run(atom(), :enabled | :all | :web | :desktop, keyword()) ::
          {:ok, [Check.t()]} | {:error, [Check.t()]}
  def run(otp_app, selection \\ :enabled, options \\ []) do
    with {:ok, project} <- Config.load(otp_app, options),
         {:ok, targets} <- select_targets(project, selection) do
      prepare(targets, Keyword.put(options, :cd, project.client_root))
    else
      {:error, error} -> {:error, [failed(:configuration, Exception.message(error))]}
    end
  end

  defp select_targets(project, :enabled), do: {:ok, project.targets |> Map.keys() |> Enum.sort()}
  defp select_targets(_project, :all), do: {:ok, [:web, :desktop]}
  defp select_targets(_project, target) when target in [:web, :desktop], do: {:ok, [target]}

  defp select_targets(_project, target),
    do: {:error, ArgumentError.exception("unknown setup target: #{inspect(target)}")}

  defp prepare(targets, options) do
    case executables(options) do
      {:ok, checks} ->
        case prepare_rust_targets(targets, options) do
          {:ok, target_checks} ->
            case prepare_wasm_bindgen(targets, options) do
              {:ok, wasm_checks} -> {:ok, checks ++ target_checks ++ wasm_checks}
              {:error, wasm_checks} -> {:error, checks ++ target_checks ++ wasm_checks}
            end

          {:error, target_checks} ->
            {:error, checks ++ target_checks}
        end

      {:error, checks} ->
        {:error, checks}
    end
  end

  defp executables(options) do
    rustup = Toolchain.rustup_path(options)

    checks = [
      cargo_check(options),
      executable_check(:rustup, rustup)
    ]

    if Enum.all?(checks, &(&1.status == :ok)), do: {:ok, checks}, else: {:error, checks}
  end

  defp executable_check(name, path) do
    if Path.type(path) == :absolute and File.regular?(path) do
      passed(name, "#{name} found at #{path}")
    else
      failed(name, "#{name} executable was not found")
    end
  end

  defp cargo_check(options) do
    case Toolchain.cargo_version(options) do
      {:ok, version} ->
        passed(:cargo, "cargo #{version} found at #{Toolchain.cargo_path(options)}")

      {:error, error} ->
        failed(:cargo, Exception.message(error))
    end
  end

  defp prepare_rust_targets(targets, options) do
    case Toolchain.installed_rust_targets(options) do
      {:ok, installed} ->
        Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, checks} ->
          triple = Map.fetch!(@rust_targets, target)

          if triple in installed do
            {:cont, {:ok, checks ++ [passed(:"rust_#{target}", "#{triple} is installed")]}}
          else
            case install_and_verify_rust_target(triple, options) do
              :ok ->
                {:cont,
                 {:ok, checks ++ [changed(:"rust_#{target}", "installed Rust target #{triple}")]}}

              {:error, error} ->
                {:halt, {:error, checks ++ [failed(:"rust_#{target}", Exception.message(error))]}}
            end
          end
        end)

      {:error, error} ->
        {:error, [failed(:rust_targets, Exception.message(error))]}
    end
  end

  defp install_and_verify_rust_target(triple, options) do
    with :ok <- Toolchain.install_rust_target(triple, options),
         {:ok, installed} <- Toolchain.installed_rust_targets(options),
         true <- triple in installed do
      :ok
    else
      false ->
        {:error,
         Toolchain.Error.new(
           :rust_target_verification_failed,
           "rustup completed but #{triple} is still missing"
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp prepare_wasm_bindgen([:desktop], _options), do: {:ok, []}

  defp prepare_wasm_bindgen(_targets, options) do
    version = Toolchain.wasm_bindgen_version()

    case Toolchain.resolve_wasm_bindgen(version, options) do
      {:ok, path} ->
        {:ok, [passed(:wasm_bindgen, "wasm-bindgen #{version} found at #{path}")]}

      {:error, _missing} ->
        case Toolchain.install_wasm_bindgen(version, options) do
          {:ok, path} ->
            {:ok, [changed(:wasm_bindgen, "installed wasm-bindgen #{version} at #{path}")]}

          {:error, error} ->
            {:error, [failed(:wasm_bindgen, Exception.message(error))]}
        end
    end
  end

  defp passed(name, message), do: %Check{name: name, status: :ok, message: message}
  defp changed(name, message), do: %Check{name: name, status: :changed, message: message}
  defp failed(name, message), do: %Check{name: name, status: :error, message: message}
end
