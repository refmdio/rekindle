defmodule Rekindle.Plugin.Cargo do
  @moduledoc """
  Cargo manifest data declared by a Rekindle plugin.

  It intentionally models only the manifest sections used by supported UI
  plugins. Cargo remains authoritative once the application owns the generated
  project.
  """

  defmodule Dependency do
    @moduledoc """
    One Cargo dependency declared by a plugin.

    Use `version` for registry dependencies or `git` and `rev` for a pinned Git
    dependency. `default_features` and `features` map to their Cargo manifest
    equivalents.
    """

    @enforce_keys [:name]
    defstruct [:name, :version, :git, :rev, default_features: nil, features: []]

    @type t :: %__MODULE__{
            name: String.t(),
            version: String.t() | nil,
            git: String.t() | nil,
            rev: String.t() | nil,
            default_features: boolean() | nil,
            features: [String.t()]
          }
  end

  alias __MODULE__.Dependency

  @enforce_keys [:dependencies]
  defstruct dependencies: [],
            target_dependencies: [],
            build_dependencies: [],
            profiles: []

  @type dependency_group :: {String.t(), [Dependency.t()]}
  @type profile :: {String.t(), keyword()}
  @type t :: %__MODULE__{
          dependencies: [Dependency.t()],
          target_dependencies: [dependency_group()],
          build_dependencies: [Dependency.t()],
          profiles: [profile()]
        }

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = cargo) do
    dependencies?(cargo.dependencies) and
      dependency_groups?(cargo.target_dependencies) and
      dependencies?(cargo.build_dependencies) and
      profiles?(cargo.profiles)
  end

  def valid?(_cargo), do: false

  @spec render(t(), [Rekindle.Plugin.Spec.target()]) :: String.t()
  def render(%__MODULE__{} = cargo, targets) do
    [
      package(),
      features(),
      dependency_section("dependencies", cargo.dependencies),
      Enum.map(cargo.target_dependencies, fn {target, dependencies} ->
        dependency_section("target.'#{target}'.dependencies", dependencies)
      end),
      dependency_section("build-dependencies", cargo.build_dependencies),
      bins(targets),
      profiles(cargo.profiles)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp package do
    """
    [package]
    name = "client"
    version = "0.1.0"
    edition = "2024"
    publish = false
    """
    |> String.trim_trailing()
  end

  defp features do
    """
    [features]
    desktop = []
    web = []
    """
    |> String.trim_trailing()
  end

  defp dependency_section(_name, []), do: nil

  defp dependency_section(name, dependencies) do
    body = Enum.map_join(dependencies, "\n", &render_dependency/1)
    "[#{name}]\n#{body}"
  end

  defp render_dependency(%Dependency{name: name} = dependency) do
    fields =
      [
        version: dependency.version,
        git: dependency.git,
        rev: dependency.rev,
        "default-features": dependency.default_features,
        features: dependency.features
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, []] end)

    case fields do
      [{:version, version}] ->
        "#{name} = #{quote_string(version)}"

      fields ->
        value =
          fields
          |> Enum.map_join(", ", fn
            {:features, features} -> "features = #{string_array(features)}"
            {key, value} when is_boolean(value) -> "#{key} = #{value}"
            {key, value} -> "#{key} = #{quote_string(value)}"
          end)

        "#{name} = { #{value} }"
    end
  end

  defp bins(targets) do
    Enum.map(targets, fn target ->
      """
      [[bin]]
      name = "#{target}"
      path = "src/bin/#{target}.rs"
      required-features = ["#{target}"]
      """
      |> String.trim_trailing()
    end)
  end

  defp profiles(profiles) do
    Enum.map(profiles, fn {name, values} ->
      body =
        Enum.map_join(values, "\n", fn
          {key, value} when is_binary(value) -> "#{key} = #{quote_string(value)}"
          {key, value} -> "#{key} = #{value}"
        end)

      "[profile.#{name}]\n#{body}"
    end)
  end

  defp quote_string(value), do: inspect(value)

  defp string_array(values) do
    "[" <> Enum.map_join(values, ", ", &quote_string/1) <> "]"
  end

  defp dependencies?(dependencies) when is_list(dependencies),
    do: Enum.all?(dependencies, &dependency?/1)

  defp dependencies?(_dependencies), do: false

  defp dependency?(%Dependency{} = dependency) do
    valid_dependency_name?(dependency.name) and
      valid_dependency_source?(dependency) and
      dependency.default_features in [nil, true, false] and
      non_empty_strings?(dependency.features)
  end

  defp dependency?(_dependency), do: false

  defp valid_dependency_name?(name) when is_binary(name),
    do: Regex.match?(~r/\A[[:alnum:]_-]+\z/, name)

  defp valid_dependency_name?(_name), do: false

  defp valid_dependency_source?(%Dependency{version: version, git: nil, rev: nil}),
    do: non_empty_string?(version)

  defp valid_dependency_source?(%Dependency{version: nil, git: git, rev: rev}),
    do: non_empty_string?(git) and non_empty_string?(rev)

  defp valid_dependency_source?(_dependency), do: false

  defp non_empty_strings?(values) when is_list(values),
    do: Enum.all?(values, &non_empty_string?/1)

  defp non_empty_strings?(_values), do: false

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp dependency_groups?(groups) when is_list(groups) do
    Enum.all?(groups, fn
      {target, dependencies} ->
        is_binary(target) and target != "" and dependencies?(dependencies)

      _group ->
        false
    end)
  end

  defp dependency_groups?(_groups), do: false

  defp profiles?(profiles) when is_list(profiles) do
    Enum.all?(profiles, fn
      {name, values} when is_binary(name) and name != "" ->
        Keyword.keyword?(values)

      _profile ->
        false
    end)
  end

  defp profiles?(_profiles), do: false
end
