if Code.ensure_loaded?(Igniter) do
  defmodule Rekindle.Install do
    @moduledoc """
    Installs Rekindle and generates the selected plugin's Rust client.

    External plugin packages can call `run/2` from their own Igniter task with
    the plugin module already selected:

        Rekindle.Install.run(igniter,
          plugin: MyUi.RekindlePlugin,
          targets: [:web, :desktop]
        )

    The regular Rekindle installer accepts the built-in `gpui`, `egui`, and
    `slint` aliases.
    """

    alias Igniter.Code.{Common, Function}
    alias Igniter.Project.{Application, TaskAliases}
    alias Igniter.Project.Config, as: ProjectConfig
    alias Rekindle.{Config, Plugin}
    alias Rekindle.Install.Client
    alias Rekindle.Phoenix.Install, as: PhoenixInstall

    @targets [:web, :desktop]

    @spec run(Igniter.t(), keyword()) :: Igniter.t()
    def run(igniter, options) do
      app = Application.app_name(igniter)
      {igniter, endpoint} = Igniter.Libs.Phoenix.select_endpoint(igniter)
      cargo_exists? = Igniter.exists?(igniter, "client/Cargo.toml")

      igniter =
        if cargo_exists?,
          do: Igniter.include_existing_file(igniter, "client/Cargo.toml"),
          else: igniter

      with :ok <- endpoint_required(endpoint),
           {:ok, requested} <- requested_selection(options),
           {:ok, existing} <- existing_selection(igniter, app),
           {:ok, selection, mode} <-
             select(requested, existing, cargo_exists?),
           {:ok, mode} <- validate_generated_paths(igniter, selection, mode),
           {:ok, igniter, phoenix} <-
             PhoenixInstall.prepare(igniter, app, endpoint, selection) do
        install(igniter, app, endpoint, selection, mode, phoenix)
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp endpoint_required(endpoint) when is_atom(endpoint) and not is_nil(endpoint), do: :ok
    defp endpoint_required(_endpoint), do: {:error, "Rekindle requires a Phoenix endpoint"}

    defp requested_selection(options) do
      with {:ok, plugin} <- requested_plugin(options[:plugin]),
           {:ok, targets} <- requested_targets(options[:targets]) do
        {:ok, %{plugin: plugin, targets: targets}}
      end
    end

    defp requested_plugin(nil), do: {:ok, nil}

    defp requested_plugin(value) when is_atom(value) do
      case Plugin.builtin(value) do
        {:ok, module} -> {:ok, module}
        :error -> validate_requested_plugin(value)
      end
    end

    defp requested_plugin(value) when is_binary(value) do
      case Plugin.builtin(value) do
        {:ok, module} -> {:ok, module}
        :error -> {:error, plugin_error(value)}
      end
    end

    defp requested_plugin({_module, options} = value) when is_list(options),
      do: validate_requested_plugin(value)

    defp requested_plugin(value), do: {:error, plugin_error(value)}

    defp validate_requested_plugin(value) do
      case Plugin.load(value) do
        {:ok, _loaded} -> {:ok, value}
        {:error, _message} -> {:error, plugin_error(value)}
      end
    end

    defp plugin_error(value) do
      "expected --plugin to be gpui, egui, or slint; got: #{inspect(value)}"
    end

    defp requested_targets(nil), do: {:ok, nil}

    defp requested_targets(values) when is_binary(values),
      do: values |> String.split(",", trim: true) |> requested_targets()

    defp requested_targets(values) when is_list(values) do
      names = Enum.map(values, &to_string/1)

      if names != [] and Enum.all?(names, &(&1 in ["web", "desktop"])) do
        {:ok, Enum.filter(@targets, &(Atom.to_string(&1) in names))}
      else
        {:error, "expected --targets to be web, desktop, or web,desktop"}
      end
    end

    defp requested_targets(_value),
      do: {:error, "expected --targets to be web, desktop, or web,desktop"}

    defp existing_selection(igniter, app) do
      config_path = Application.config_path(igniter)
      igniter = Igniter.include_existing_file(igniter, config_path)
      source = Rewrite.source!(igniter.rewrite, config_path)
      zipper = source |> Rewrite.Source.get(:quoted) |> Sourceror.Zipper.zip()

      case Common.move_to(zipper, fn zipper ->
             Function.function_call?(zipper, :config, 3) and
               Function.argument_equals?(zipper, 0, app) and
               Function.argument_equals?(zipper, 1, Rekindle)
           end) do
        :error ->
          {:ok, nil}

        {:ok, zipper} ->
          with {:ok, zipper} <- Function.move_to_nth_argument(zipper, 2),
               {:ok, config} <- Common.expand_literal(zipper),
               :ok <- validate_existing_config(config),
               plugin <- Keyword.fetch!(config, :plugin),
               targets <- Keyword.fetch!(config, :targets) do
            {:ok,
             %{
               config: config,
               plugin: plugin,
               targets: Enum.filter(@targets, &Keyword.has_key?(targets, &1))
             }}
          else
            _ -> {:error, "existing Rekindle configuration is not a valid static selection"}
          end
      end
    end

    defp validate_existing_config(config) do
      case Config.validate(config) do
        :ok -> :ok
        {:error, _error} -> false
      end
    end

    defp select(requested, nil, false) do
      {:ok,
       %{
         plugin: requested.plugin || Rekindle.Plugin.GPUI,
         targets: requested.targets || @targets
       }, :generate}
    end

    defp select(_requested, nil, true),
      do: {:error, "client/Cargo.toml already exists; Rekindle will not overwrite it"}

    defp select(requested, existing, true) do
      with :ok <- same_or_omitted(:plugin, requested.plugin, existing.plugin),
           :ok <- same_or_omitted(:targets, requested.targets, existing.targets) do
        {:ok, existing, :existing}
      end
    end

    defp select(_requested, _existing, false) do
      {:error, "Rekindle is configured but client/Cargo.toml is missing"}
    end

    defp same_or_omitted(_name, nil, _existing), do: :ok
    defp same_or_omitted(_name, value, value), do: :ok

    defp same_or_omitted(name, requested, existing) do
      {:error,
       "requested #{name} #{inspect(requested)} conflicts with existing Rekindle configuration #{inspect(existing)}"}
    end

    defp validate_generated_paths(igniter, selection, :generate) do
      generated_paths =
        selection.plugin
        |> Client.render(selection.targets)
        |> Map.keys()

      generated_paths
      |> Enum.find(&Igniter.exists?(igniter, Path.join("client", &1)))
      |> case do
        nil -> {:ok, :generate}
        path -> {:error, "client/#{path} already exists; Rekindle will not overwrite it"}
      end
    end

    defp validate_generated_paths(_igniter, _selection, :existing), do: {:ok, :existing}

    defp install(igniter, app, endpoint, selection, mode, phoenix) do
      igniter
      |> maybe_generate_client(selection, mode)
      |> configure(app, selection)
      |> PhoenixInstall.install(app, endpoint, selection, phoenix)
      |> update_setup_aliases()
      |> maybe_add_web_alias(selection.targets)
      |> TaskAliases.add_alias(:precommit, ["rekindle.check"], if_exists: :append)
      |> update_ignores(selection)
    end

    defp update_setup_aliases(igniter) do
      igniter
      |> TaskAliases.modify_existing_alias(:setup, fn zipper ->
        with {:ok, zipper} <-
               Igniter.Code.List.remove_from_list(
                 zipper,
                 &Igniter.Code.Common.nodes_equal?(&1, "rekindle.setup")
               ),
             {:ok, zipper} <-
               Igniter.Code.List.append_new_to_list(zipper, "assets.setup") do
          {:ok, zipper}
        end
      end)
      |> TaskAliases.add_alias(:"assets.setup", ["rekindle.setup"], if_exists: :append)
    end

    defp maybe_generate_client(igniter, _selection, :existing), do: igniter

    defp maybe_generate_client(igniter, selection, :generate) do
      selection.plugin
      |> Client.render(selection.targets)
      |> Enum.reduce(igniter, fn {relative, contents}, igniter ->
        Igniter.create_new_file(igniter, Path.join("client", relative), contents)
      end)
      |> Igniter.mkdir("client/public")
    end

    defp configure(igniter, app, selection) when not is_map_key(selection, :config) do
      targets = Enum.map(selection.targets, &{&1, []})

      ProjectConfig.configure_new(
        igniter,
        "config.exs",
        app,
        [Rekindle],
        plugin: selection.plugin,
        targets: targets
      )
    end

    defp configure(igniter, app, selection) do
      existing_targets = Keyword.fetch!(selection.config, :targets)

      targets =
        Enum.map(selection.targets, fn target ->
          {target, Keyword.get(existing_targets, target, [])}
        end)

      ProjectConfig.configure(
        igniter,
        "config.exs",
        app,
        [Rekindle, :targets],
        targets
      )
    end

    defp maybe_add_web_alias(igniter, targets) do
      if :web in targets do
        igniter
        |> TaskAliases.add_alias(:"assets.build", ["rekindle.build web"], if_exists: :append)
        |> TaskAliases.add_alias(
          :"assets.deploy",
          ["rekindle.build web --release"],
          if_exists: :prepend
        )
      else
        igniter
      end
    end

    defp update_ignores(igniter, selection) do
      entries =
        ["/.rekindle/", "/client/target/"] ++
          if(:web in selection.targets,
            do: ["/priv/static/rekindle/"],
            else: []
          ) ++
          if(:desktop in selection.targets, do: ["/dist/rekindle/"], else: [])

      Igniter.create_or_update_file(igniter, ".gitignore", "", fn source ->
        content = Rewrite.Source.get(source, :content)
        existing = MapSet.new(String.split(content, "\n"))
        missing = Enum.reject(entries, &MapSet.member?(existing, &1))

        updated =
          case missing do
            [] ->
              content

            missing ->
              separator = if content == "" or String.ends_with?(content, "\n"), do: "", else: "\n"

              IO.iodata_to_binary([
                content,
                separator,
                Enum.intersperse(missing, "\n"),
                "\n"
              ])
          end

        Rewrite.Source.update(source, :content, updated)
      end)
    end
  end
end
