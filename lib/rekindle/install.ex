if Code.ensure_loaded?(Igniter) do
  defmodule Rekindle.Install do
    @moduledoc false

    alias Igniter.Code.{Common, Function}
    alias Igniter.Project.{Application, TaskAliases}
    alias Igniter.Project.Config, as: ProjectConfig
    alias Rekindle.{Config, Integration}

    @targets [:web, :desktop]

    @spec run(Igniter.t(), keyword()) :: Igniter.t()
    def run(igniter, options) do
      app = Application.app_name(igniter)

      with {:ok, requested} <- requested_selection(options),
           {:ok, existing} <- existing_selection(igniter, app),
           {:ok, selection, mode} <-
             select(requested, existing, Igniter.exists?(igniter, "client/Cargo.toml")),
           :ok <- validate_client(igniter, selection, mode) do
        install(igniter, app, selection, mode)
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

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
         integration: requested.integration || :gpui,
         targets: requested.targets || @targets
       }, :generate}
    end

    defp select(%{integration: nil}, nil, true) do
      {:error, "client/Cargo.toml already exists; --integration is required to adopt it"}
    end

    defp select(%{targets: nil}, nil, true) do
      {:error, "client/Cargo.toml already exists; --targets is required to adopt it"}
    end

    defp select(requested, nil, true) do
      {:ok, requested, :adopt}
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
        nil -> :ok
        path -> {:error, "client/#{path} already exists; Rekindle will not overwrite it"}
      end
    end

    defp validate_client(_igniter, _selection, :existing), do: :ok

    defp validate_client(igniter, selection, :adopt) do
      with {:ok, manifest} <- read_manifest(igniter),
           :ok <- package(manifest),
           :ok <- direct_dependencies(manifest, selection.integration, selection.targets),
           :ok <- cargo_targets(manifest, selection.targets),
           :ok <- target_entries(igniter, selection.targets) do
        :ok
      end
    end

    defp read_manifest(igniter) do
      igniter = Igniter.include_existing_file(igniter, "client/Cargo.toml", required?: true)
      contents = igniter.rewrite.sources["client/Cargo.toml"] |> Rewrite.Source.get(:content)

      case TomlElixir.decode(contents) do
        {:ok, %{"package" => package} = manifest} when is_map(package) ->
          {:ok, manifest}

        {:ok, _manifest} ->
          {:error, "client/Cargo.toml must describe a Cargo package"}

        {:error, error} ->
          {:error, "client/Cargo.toml is invalid: #{Exception.message(error)}"}
      end
    end

    defp package(%{"package" => %{"name" => name}}) when is_binary(name) and name != "", do: :ok
    defp package(_manifest), do: {:error, "client/Cargo.toml package requires a non-empty name"}

    defp direct_dependencies(manifest, selected, targets) do
      with :ok <- target_table(manifest) do
        Enum.reduce_while(targets, :ok, fn target, :ok ->
          case direct_dependency(manifest, selected, target) do
            :ok -> {:cont, :ok}
            {:error, message} -> {:halt, {:error, message}}
          end
        end)
      end
    end

    defp direct_dependency(manifest, selected, target) do
      integrations =
        manifest
        |> dependency_tables(target)
        |> Enum.flat_map(fn dependencies ->
          Enum.flat_map(dependencies, fn {name, requirement} ->
            package =
              if is_map(requirement), do: Map.get(requirement, "package", name), else: name

            case package do
              "gpui" -> [:gpui]
              "eframe" -> [:egui]
              "slint" -> [:slint]
              _ -> []
            end
          end)
        end)
        |> Enum.uniq()

      case integrations do
        [^selected] ->
          :ok

        [] ->
          {:error,
           "client/Cargo.toml has no direct #{Integration.dependency(selected)} dependency for #{target}"}

        [found] ->
          {:error,
           "client/Cargo.toml dependency #{found} does not match the selected #{selected} integration"}

        found ->
          {:error,
           "client/Cargo.toml has ambiguous UI framework dependencies: #{Enum.join(found, ", ")}"}
      end
    end

    defp target_table(%{"target" => target}) when not is_map(target),
      do: {:error, "client/Cargo.toml target section must contain target tables"}

    defp target_table(_manifest), do: :ok

    defp dependency_tables(manifest, target) do
      root =
        case manifest["dependencies"] do
          dependencies when is_map(dependencies) -> [dependencies]
          _ -> []
        end

      target =
        manifest
        |> Map.get("target", %{})
        |> Enum.flat_map(fn
          {selector, %{"dependencies" => dependencies}}
          when is_map(dependencies) and is_binary(selector) ->
            if selector_applies?(selector, target), do: [dependencies], else: []

          {_selector, %{"dependencies" => _dependencies}} ->
            []

          {_selector, _table} ->
            []
        end)

      root ++ target
    end

    defp selector_applies?("wasm32-unknown-unknown", :web), do: true
    defp selector_applies?("wasm32-unknown-unknown", :desktop), do: false

    defp selector_applies?(selector, target) do
      compact = String.replace(selector, ~r/\s+/, "")

      wasm =
        String.contains?(compact, ~s(target_arch="wasm32")) or
          String.contains?(compact, ~s(target_family="wasm"))

      negated = String.starts_with?(compact, "cfg(not(")

      case {target, wasm, negated} do
        {:web, true, false} -> true
        {:desktop, true, true} -> true
        _ -> false
      end
    end

    defp cargo_targets(manifest, targets) do
      package = Map.fetch!(manifest, "package")

      case Map.get(package, "autobins", true) do
        value when is_boolean(value) ->
          Enum.reduce_while(targets, :ok, fn target, :ok ->
            if value or explicit_bin?(manifest, target) do
              {:cont, :ok}
            else
              {:halt,
               {:error,
                "client/Cargo.toml does not define the #{target} binary while package.autobins is false"}}
            end
          end)

        _value ->
          {:error, "client/Cargo.toml package.autobins must be a boolean"}
      end
    end

    defp explicit_bin?(manifest, target) do
      expected_name = Atom.to_string(target)
      expected_path = "src/bin/#{target}.rs"

      manifest
      |> Map.get("bin", [])
      |> List.wrap()
      |> Enum.any?(fn
        %{"name" => ^expected_name, "path" => ^expected_path} -> true
        _bin -> false
      end)
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

    defp install(igniter, app, selection, mode) do
      igniter
      |> maybe_generate_client(selection, mode)
      |> configure(app, selection)
      |> Application.add_new_child(
        {Rekindle, {:code, Sourceror.parse_string!("[otp_app: #{inspect(app)}]")}}
      )
      |> TaskAliases.add_alias(:setup, "rekindle.setup", if_exists: :append)
      |> maybe_add_web_alias(selection.targets)
      |> update_ignores(selection.targets, mode)
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
          {target, [features: [Atom.to_string(target)]]}
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

    defp update_ignores(igniter, targets, mode) do
      entries =
        ["/.rekindle/"] ++
          if(mode == :generate, do: ["/client/target/"], else: []) ++
          if(:web in targets, do: ["/priv/static/rekindle/"], else: []) ++
          if(:desktop in targets, do: ["/dist/rekindle/"], else: [])

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
