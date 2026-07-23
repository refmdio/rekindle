defmodule Rekindle.Config do
  @moduledoc false

  alias Rekindle.Config.{Error, Target}

  @integrations Rekindle.Integration.names()
  @target_names [:web, :desktop]
  @config_keys [:integration, :targets, :public_dir]
  @target_keys [:package, :binary, :features, :profiles]
  @profile_names [:dev, :release]

  @enforce_keys [:otp_app, :root, :client_root, :integration, :targets, :public_dir]
  defstruct [:otp_app, :root, :client_root, :integration, :targets, :public_dir]

  @type t :: %__MODULE__{
          otp_app: atom(),
          root: Path.t(),
          client_root: Path.t(),
          integration: :gpui | :egui | :slint,
          targets: %{optional(:web | :desktop) => Target.t()},
          public_dir: Path.t()
        }

  @spec load(atom(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def load(otp_app, options \\ []) when is_atom(otp_app) do
    configured_root = options |> Keyword.get(:project_root, File.cwd!()) |> Path.expand()

    with {:ok, root} <- resolve_path(configured_root),
         {:ok, config} <- fetch(otp_app),
         {:ok, parsed} <- parse(config),
         {:ok, client_root} <- project_path(root, "client"),
         {:ok, public_dir} <- project_path(root, parsed.public_dir) do
      {:ok,
       %__MODULE__{
         otp_app: otp_app,
         root: root,
         client_root: client_root,
         integration: parsed.integration,
         targets: parsed.targets,
         public_dir: public_dir
       }}
    end
  end

  @doc false
  @spec validate(keyword(), keyword()) :: :ok | {:error, Error.t()}
  def validate(config, options \\ []) do
    root = options |> Keyword.get(:project_root, File.cwd!()) |> Path.expand()

    case parse(config) do
      {:ok, parsed} ->
        case project_path(root, parsed.public_dir) do
          {:ok, _public_dir} -> :ok
          {:error, %Error{} = error} -> {:error, error}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp parse(config) do
    with :ok <- keyword(config, "Rekindle configuration"),
         :ok <- unique_keys(config, "Rekindle configuration"),
         :ok <- known_keys(config, @config_keys, "Rekindle configuration"),
         {:ok, integration} <- integration(config),
         {:ok, targets} <- targets(config),
         {:ok, public_dir} <- public_dir(config) do
      {:ok, %{integration: integration, targets: targets, public_dir: public_dir}}
    end
  end

  defp public_dir(config) do
    case Keyword.get(config, :public_dir, "priv/static") do
      value when is_binary(value) ->
        {:ok, value}

      value ->
        error(
          :invalid_path,
          "expected :public_dir to be a project-relative path, got: #{inspect(value)}"
        )
    end
  end

  defp fetch(otp_app) do
    case Application.fetch_env(otp_app, Rekindle) do
      {:ok, config} ->
        {:ok, config}

      :error ->
        error(
          :missing_configuration,
          "Rekindle is not configured for #{inspect(otp_app)}; run the installer or add the application configuration"
        )
    end
  end

  defp integration(config) do
    case Keyword.fetch(config, :integration) do
      {:ok, value} when value in @integrations ->
        {:ok, value}

      {:ok, value} ->
        error(
          :invalid_integration,
          "expected :integration to be one of #{inspect(@integrations)}, got: #{inspect(value)}"
        )

      :error ->
        error(:missing_integration, "Rekindle configuration requires :integration")
    end
  end

  defp targets(config) do
    case Keyword.fetch(config, :targets) do
      {:ok, []} ->
        error(:missing_targets, "Rekindle configuration must enable :web, :desktop, or both")

      {:ok, value} ->
        with :ok <- keyword(value, ":targets"),
             :ok <- unique_keys(value, ":targets"),
             :ok <- known_keys(value, @target_names, ":targets") do
          Enum.reduce_while(value, {:ok, %{}}, fn {name, target_config}, {:ok, targets} ->
            case target(name, target_config) do
              {:ok, target} -> {:cont, {:ok, Map.put(targets, name, target)}}
              {:error, error} -> {:halt, {:error, error}}
            end
          end)
        end

      :error ->
        error(:missing_targets, "Rekindle configuration requires :targets")
    end
  end

  defp target(name, config) do
    with :ok <- keyword(config, "#{name} target"),
         :ok <- unique_keys(config, "#{name} target"),
         :ok <- known_keys(config, @target_keys, "#{name} target"),
         {:ok, package} <- optional_string(config, :package, name),
         {:ok, binary} <- optional_string(config, :binary, name),
         {:ok, features} <- features(config, name),
         {:ok, profiles} <- profiles(config, name) do
      {:ok,
       %Target{
         name: name,
         entry: Path.join(["client", "src", "bin", "#{name}.rs"]),
         package: package,
         binary: binary,
         features: features,
         profiles: profiles
       }}
    end
  end

  defp features(config, target) do
    value = Keyword.get(config, :features, [])

    if is_list(value) and Enum.all?(value, &(is_binary(&1) and &1 != "")) do
      {:ok, value}
    else
      error(:invalid_features, "expected #{target} :features to be a list of non-empty strings")
    end
  end

  defp profiles(config, target) do
    value = Keyword.get(config, :profiles, dev: "dev", release: "release")

    with :ok <- keyword(value, "#{target} :profiles"),
         :ok <- unique_keys(value, "#{target} :profiles"),
         :ok <- known_keys(value, @profile_names, "#{target} :profiles"),
         true <-
           Enum.all?(@profile_names, fn name ->
             case Keyword.fetch(value, name) do
               {:ok, profile} -> is_binary(profile) and profile != ""
               :error -> false
             end
           end) do
      {:ok, Map.new(value)}
    else
      false ->
        error(
          :invalid_profiles,
          "expected #{target} :profiles to contain non-empty :dev and :release values"
        )

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp optional_string(config, key, target) do
    case Keyword.get(config, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) and value != "" ->
        {:ok, value}

      value ->
        error(
          :"invalid_#{key}",
          "expected #{target} :#{key} to be a non-empty string, got: #{inspect(value)}"
        )
    end
  end

  defp project_path(root, relative) when is_binary(relative) do
    if Path.type(relative) == :relative do
      expanded = Path.expand(relative, root)

      with true <- expanded == root or String.starts_with?(expanded, root <> "/"),
           {:ok, resolved} <- resolve_path(expanded),
           true <- resolved == root or String.starts_with?(resolved, root <> "/") do
        {:ok, resolved}
      else
        false -> error(:invalid_path, "path must remain inside the project: #{inspect(relative)}")
        {:error, %Error{} = error} -> {:error, error}
      end
    else
      error(:invalid_path, "path must be project-relative: #{inspect(relative)}")
    end
  end

  defp resolve_path(path), do: resolve_path(Path.split(Path.expand(path)), nil, 40)

  defp resolve_path(_parts, _resolved, 0),
    do: error(:invalid_path, "path contains too many symbolic links")

  defp resolve_path([], resolved, _links), do: {:ok, resolved}

  defp resolve_path([part | rest], nil, links),
    do: resolve_path(rest, part, links)

  defp resolve_path([part | rest], resolved, links) do
    candidate = Path.join(resolved, part)

    case File.read_link(candidate) do
      {:ok, target} ->
        target =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.expand(target, Path.dirname(candidate))

        resolve_path(Path.split(target) ++ rest, nil, links - 1)

      {:error, :einval} ->
        resolve_path(rest, candidate, links)

      {:error, :enoent} ->
        {:ok, Path.join([candidate | rest])}

      {:error, reason} ->
        error(:invalid_path, "cannot resolve path #{inspect(candidate)}: #{inspect(reason)}")
    end
  end

  defp keyword(value, label) do
    if Keyword.keyword?(value) do
      :ok
    else
      error(:invalid_configuration, "expected #{label} to be a keyword list")
    end
  end

  defp unique_keys(value, label) do
    keys = Keyword.keys(value)

    if length(keys) == MapSet.size(MapSet.new(keys)) do
      :ok
    else
      error(:duplicate_key, "#{label} contains a duplicate key")
    end
  end

  defp known_keys(value, allowed, label) do
    case Keyword.keys(value) -- allowed do
      [] -> :ok
      unknown -> error(:unknown_key, "#{label} contains unknown keys: #{inspect(unknown)}")
    end
  end

  defp error(kind, message), do: {:error, Error.new(kind, message)}
end
