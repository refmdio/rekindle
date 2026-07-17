defmodule Rekindle.Cargo.Arguments do
  @moduledoc false

  alias Rekindle.Config.{DesktopTarget, WebTarget}

  defmodule Request do
    @moduledoc false
    @enforce_keys [:operation, :cwd, :manifest_path, :argv, :selection]
    defstruct @enforce_keys

    @type operation :: :metadata | :build
    @type t :: %__MODULE__{
            operation: operation(),
            cwd: Path.t(),
            manifest_path: Path.t(),
            argv: [String.t()],
            selection: map()
          }
  end

  @type target_config :: WebTarget.t() | DesktopTarget.t()

  @spec metadata(Path.t(), Rekindle.target(), target_config(), Rekindle.build_mode(), String.t()) ::
          {:ok, Request.t()} | {:error, Rekindle.Failure.t()}
  def metadata(client_root, target, config, mode, rust_target) do
    request(:metadata, client_root, target, config, mode, rust_target)
  end

  @spec build(Path.t(), Rekindle.target(), target_config(), Rekindle.build_mode(), String.t()) ::
          {:ok, Request.t()} | {:error, Rekindle.Failure.t()}
  def build(client_root, target, config, mode, rust_target) do
    request(:build, client_root, target, config, mode, rust_target)
  end

  defp request(operation, client_root, target, config, mode, rust_target)
       when operation in [:metadata, :build] and target in [:web, :desktop] and
              mode in [:dev, :release] do
    with :ok <- target_config(target, config),
         :ok <- absolute_path(client_root),
         :ok <- identifier(rust_target),
         {:ok, profile} <- profile(config, mode),
         :ok <- identifier(config.package),
         :ok <- identifier(config.binary),
         {:ok, features} <- features(config.features),
         true <- is_boolean(config.default_features) do
      manifest_path = Path.join(client_root, "Cargo.toml")

      selection = %{
        target: target,
        package: config.package,
        binary: config.binary,
        rust_target: rust_target,
        profile: profile,
        features: features,
        default_features: config.default_features
      }

      argv =
        case operation do
          :metadata ->
            metadata_argv(manifest_path, rust_target, features, config.default_features)

          :build ->
            build_argv(manifest_path, selection)
        end

      {:ok,
       %Request{
         operation: operation,
         cwd: client_root,
         manifest_path: manifest_path,
         argv: argv,
         selection: selection
       }}
    else
      _ -> failure(target, :cargo_metadata_failed, "Cargo request fields are invalid")
    end
  end

  defp request(_operation, _client_root, target, _config, _mode, _rust_target),
    do:
      failure(
        normalize_target(target),
        :cargo_metadata_failed,
        "Cargo request fields are invalid"
      )

  defp metadata_argv(manifest_path, rust_target, features, default_features) do
    [
      "metadata",
      "--format-version",
      "1",
      "--locked",
      "--filter-platform",
      rust_target,
      "--manifest-path",
      manifest_path
    ] ++ feature_argv(features, default_features)
  end

  defp build_argv(manifest_path, selection) do
    [
      "build",
      "--message-format=json-render-diagnostics",
      "--locked",
      "--manifest-path",
      manifest_path,
      "--package",
      selection.package,
      "--bin",
      selection.binary,
      "--profile",
      selection.profile,
      "--target",
      selection.rust_target
    ] ++ feature_argv(selection.features, selection.default_features)
  end

  defp feature_argv(features, default_features) do
    default = if default_features, do: [], else: ["--no-default-features"]
    enabled = if features == [], do: [], else: ["--features", Enum.join(features, ",")]
    default ++ enabled
  end

  defp target_config(:web, %WebTarget{}), do: :ok
  defp target_config(:desktop, %DesktopTarget{}), do: :ok
  defp target_config(_, _), do: :error

  defp profile(config, mode) when is_map(config.profiles) do
    case Map.fetch(config.profiles, mode) do
      {:ok, value} -> if identifier(value) == :ok, do: {:ok, value}, else: :error
      :error -> :error
    end
  end

  defp profile(_, _), do: :error

  defp features(value) when is_list(value) do
    if proper_list?(value) and Enum.all?(value, &(identifier(&1) == :ok)) and
         length(value) == length(Enum.uniq(value)) do
      {:ok, Enum.sort(value)}
    else
      :error
    end
  end

  defp features(_), do: :error

  defp absolute_path(value) when is_binary(value) do
    if String.valid?(value) and not String.contains?(value, <<0>>) and
         Path.type(value) == :absolute and Path.expand(value) == value,
       do: :ok,
       else: :error
  end

  defp absolute_path(_), do: :error

  defp identifier(value) when is_binary(value) do
    if byte_size(value) in 1..255 and String.valid?(value) and
         not String.contains?(value, [<<0>>, "\n", "\r"]),
       do: :ok,
       else: :error
  end

  defp identifier(_), do: :error

  defp proper_list?(value), do: is_list(value) and :erlang.length(value) >= 0

  defp normalize_target(value) when value in [:web, :desktop], do: value
  defp normalize_target(_), do: nil

  defp failure(target, code, message) do
    {:error,
     Rekindle.Failure.new!(
       target: target,
       stage: :project_model,
       code: code,
       message: message
     )}
  end
end
