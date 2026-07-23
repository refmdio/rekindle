if Code.ensure_loaded?(Igniter) do
  defmodule Rekindle.Install do
    @moduledoc false

    alias Igniter.Code.{Common, Function}
    alias Igniter.Project.{Application, TaskAliases}
    alias Igniter.Project.Config, as: ProjectConfig
    alias Rekindle.{Config, Integration}
    alias Rekindle.Install.Cargo, as: InstallCargo

    @targets [:web, :desktop]

    @spec run(Igniter.t(), keyword()) :: Igniter.t()
    def run(igniter, options) do
      app = Application.app_name(igniter)
      {igniter, endpoint} = Igniter.Libs.Phoenix.select_endpoint(igniter)

      with :ok <- client_root_contained(),
           :ok <- endpoint_required(endpoint),
           {:ok, requested} <- requested_selection(options),
           {:ok, existing} <- existing_selection(igniter, app),
           {:ok, selection, mode} <-
             select(requested, existing, Igniter.exists?(igniter, "client/Cargo.toml")),
           {:ok, selection} <- validate_client(igniter, selection, mode) do
        install(igniter, app, endpoint, selection, mode)
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp client_root_contained do
      case Config.validate_client_root(File.cwd!()) do
        :ok -> :ok
        {:error, error} -> {:error, Exception.message(error)}
      end
    end

    defp endpoint_required(endpoint) when is_atom(endpoint) and not is_nil(endpoint), do: :ok
    defp endpoint_required(_endpoint), do: {:error, "Rekindle requires a Phoenix endpoint"}

    defp requested_selection(options) do
      with {:ok, integration} <- requested_integration(options[:integration]),
           {:ok, targets} <- requested_targets(options[:targets]) do
        {:ok, %{integration: integration, targets: targets}}
      end
    end

    defp requested_integration(nil), do: {:ok, nil}

    defp requested_integration(value) when is_atom(value) do
      if value in Integration.names(),
        do: {:ok, value},
        else: {:error, integration_error(value)}
    end

    defp requested_integration(value) when is_binary(value) do
      case Enum.find(Integration.names(), &(Atom.to_string(&1) == value)) do
        nil -> {:error, integration_error(value)}
        integration -> {:ok, integration}
      end
    end

    defp requested_integration(value), do: {:error, integration_error(value)}

    defp integration_error(value) do
      "expected --integration to be gpui, egui, or slint; got: #{inspect(value)}"
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
               integration <- Keyword.fetch!(config, :integration),
               targets <- Keyword.fetch!(config, :targets) do
            {:ok,
             %{
               integration: integration,
               targets: Enum.filter(@targets, &Keyword.has_key?(targets, &1)),
               public_dir: Keyword.get(config, :public_dir, "priv/static")
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
         integration: requested.integration || :gpui,
         targets: requested.targets || @targets,
         public_dir: "priv/static"
       }, :generate}
    end

    defp select(%{integration: nil}, nil, true) do
      {:error, "client/Cargo.toml already exists; --integration is required to adopt it"}
    end

    defp select(%{targets: nil}, nil, true) do
      {:error, "client/Cargo.toml already exists; --targets is required to adopt it"}
    end

    defp select(requested, nil, true) do
      {:ok, Map.put(requested, :public_dir, "priv/static"), :adopt}
    end

    defp select(requested, existing, true) do
      with :ok <- same_or_omitted(:integration, requested.integration, existing.integration),
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

    defp validate_client(igniter, selection, :generate) do
      generated_paths =
        selection.integration
        |> Integration.render(selection.targets)
        |> Map.keys()

      (generated_paths ++ ["src/bin/web.rs", "src/bin/desktop.rs"])
      |> Enum.uniq()
      |> Enum.find(&Igniter.exists?(igniter, Path.join("client", &1)))
      |> case do
        nil -> {:ok, selection}
        path -> {:error, "client/#{path} already exists; Rekindle will not overwrite it"}
      end
    end

    defp validate_client(_igniter, selection, :existing), do: {:ok, selection}

    defp validate_client(igniter, selection, :adopt) do
      with :ok <- target_entries(igniter, selection.targets),
           {:ok, target_options} <-
             InstallCargo.validate(igniter, selection.integration, selection.targets) do
        {:ok, Map.put(selection, :target_options, target_options)}
      end
    end

    defp target_entries(igniter, targets) do
      case Enum.find(targets, fn target ->
             not Igniter.exists?(igniter, "client/src/bin/#{target}.rs")
           end) do
        nil ->
          :ok

        target ->
          {:error, "client/src/bin/#{target}.rs is required to adopt the #{target} target"}
      end
    end

    defp install(igniter, app, endpoint, selection, mode) do
      igniter
      |> maybe_generate_client(selection, mode)
      |> configure(app, selection)
      |> Application.add_new_child(
        {Rekindle,
         {:code,
          Sourceror.parse_string!("[otp_app: #{inspect(app)}, endpoint: #{inspect(endpoint)}]")}}
      )
      |> TaskAliases.add_alias(:setup, "rekindle.setup", if_exists: :append)
      |> maybe_add_web_alias(selection.targets)
      |> update_ignores(selection, mode)
    end

    defp maybe_generate_client(igniter, _selection, mode) when mode != :generate, do: igniter

    defp maybe_generate_client(igniter, selection, :generate) do
      selection.integration
      |> Integration.render(selection.targets)
      |> Enum.reduce(igniter, fn {relative, contents}, igniter ->
        Igniter.create_new_file(igniter, Path.join("client", relative), contents)
      end)
      |> Igniter.mkdir("client/public")
    end

    defp configure(igniter, app, selection) do
      targets =
        Enum.map(selection.targets, fn target ->
          options =
            selection
            |> Map.get(:target_options, %{})
            |> Map.get(target, features: [Atom.to_string(target)])

          {target, options}
        end)

      ProjectConfig.configure_new(
        igniter,
        "config.exs",
        app,
        [Rekindle],
        integration: selection.integration,
        targets: targets
      )
    end

    defp maybe_add_web_alias(igniter, targets) do
      if :web in targets do
        TaskAliases.add_alias(
          igniter,
          :"assets.deploy",
          "rekindle.build web --release",
          if_exists: :prepend
        )
      else
        igniter
      end
    end

    defp update_ignores(igniter, selection, mode) do
      entries =
        ["/.rekindle/"] ++
          if(mode == :generate, do: ["/client/target/"], else: []) ++
          if(:web in selection.targets,
            do: ["/#{Path.join(selection.public_dir, "rekindle")}/"],
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
              content <> separator <> Enum.join(missing, "\n") <> "\n"
          end

        Rewrite.Source.update(source, :content, updated)
      end)
    end
  end
end
