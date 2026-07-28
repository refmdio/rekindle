defmodule Rekindle.Plugin do
  @moduledoc """
  Contract for a Rust UI framework supported by Rekindle.

  One plugin is selected for an application. Plugins declare client source,
  Cargo requirements, and browser host information; they do not run builds or
  own development processes.
  """

  alias Rekindle.Plugin.{Cargo, Spec}

  @type configured :: module() | {module(), keyword()}
  @type builtin :: :gpui | :egui | :slint | :iced

  @builtins %{
    gpui: Rekindle.Plugin.GPUI,
    egui: Rekindle.Plugin.Egui,
    slint: Rekindle.Plugin.Slint,
    iced: Rekindle.Plugin.Iced
  }

  @callback name() :: String.t()
  @callback spec(keyword()) :: Spec.t()

  @spec builtin_names() :: [builtin()]
  def builtin_names, do: [:gpui, :egui, :slint, :iced]

  @spec builtin(builtin() | String.t()) :: {:ok, module()} | :error
  def builtin(name) when is_binary(name) do
    Enum.find_value(@builtins, :error, fn {key, module} ->
      if Atom.to_string(key) == name, do: {:ok, module}
    end)
  end

  def builtin(name) when is_atom(name), do: Map.fetch(@builtins, name)
  def builtin(_name), do: :error

  @spec load(configured()) :: {:ok, {module(), keyword(), Spec.t()}} | {:error, String.t()}
  def load(configured) do
    with {:ok, module, options} <- normalize(configured),
         :ok <- validate_module(module),
         %Spec{} = spec <- module.spec(options),
         :ok <- validate_spec(module, spec) do
      {:ok, {module, options, spec}}
    else
      {:error, message} -> {:error, message}
      value -> {:error, "plugin returned an invalid spec: #{inspect(value)}"}
    end
  end

  @spec name(configured()) :: String.t()
  def name(configured) do
    {:ok, {_module, _options, spec}} = load(configured)
    spec.name
  end

  @spec spec(configured()) :: Spec.t()
  def spec(configured) do
    {:ok, {_module, _options, spec}} = load(configured)
    spec
  end

  defp normalize(module) when is_atom(module), do: {:ok, module, []}

  defp normalize({module, options}) when is_atom(module) and is_list(options) do
    if Keyword.keyword?(options),
      do: {:ok, module, options},
      else: {:error, "plugin options must be a keyword list"}
  end

  defp normalize(value) do
    {:error, "expected a plugin module or {module, options}, got: #{inspect(value)}"}
  end

  defp validate_module(module) do
    if Code.ensure_loaded?(module) and
         function_exported?(module, :name, 0) and
         function_exported?(module, :spec, 1) do
      :ok
    else
      {:error, "#{inspect(module)} does not implement Rekindle.Plugin"}
    end
  end

  defp validate_spec(module, %Spec{} = spec) do
    cond do
      spec.name != module.name() ->
        {:error, "#{inspect(module)} returned a spec with a different name"}

      not valid_name?(spec.name) ->
        {:error, "#{inspect(module)} returned an invalid plugin name"}

      not (is_binary(spec.dependency) and spec.dependency != "") ->
        {:error, "#{inspect(module)} returned an invalid Cargo dependency"}

      not valid_source?(spec.source) ->
        {:error, "#{inspect(module)} returned an invalid source root"}

      not valid_files?(spec.files) ->
        {:error, "#{inspect(module)} returned invalid source files"}

      not valid_entries?(spec.entries) ->
        {:error, "#{inspect(module)} returned invalid target entries"}

      not Cargo.valid?(spec.cargo) ->
        {:error, "#{inspect(module)} returned invalid Cargo requirements"}

      not (is_binary(spec.toolchain) and spec.toolchain != "") ->
        {:error, "#{inspect(module)} returned an invalid Rust toolchain"}

      not valid_web?(spec.web) ->
        {:error, "#{inspect(module)} returned invalid Web requirements"}

      true ->
        :ok
    end
  end

  defp valid_name?(name),
    do: is_binary(name) and Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, name)

  defp valid_source?(app) when is_atom(app), do: not is_nil(app)

  defp valid_source?({app, root}) when is_atom(app) and not is_nil(app) and is_binary(root),
    do: root == "" or valid_path?(root)

  defp valid_source?(_source), do: false

  defp valid_files?(files) when is_map(files) do
    Enum.all?(files, fn {destination, source} ->
      valid_path?(destination) and valid_path?(source)
    end)
  end

  defp valid_files?(_files), do: false

  defp valid_entries?(%{web: web, desktop: desktop} = entries) when map_size(entries) == 2,
    do: valid_path?(web) and valid_path?(desktop)

  defp valid_entries?(_entries), do: false

  defp valid_path?(path) when is_binary(path) and path != "" do
    Path.type(path) == :relative and ".." not in Path.split(path)
  end

  defp valid_path?(_path), do: false

  defp valid_web?(%Spec.Web{graphics: graphics, host: host, style: style}),
    do: graphics in [:webgpu, :webgl2] and is_binary(host) and is_binary(style)

  defp valid_web?(_web), do: false
end
