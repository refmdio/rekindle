if Code.ensure_loaded?(Igniter) do
  defmodule Rekindle.Install do
    @moduledoc false

    alias Igniter.Code.{Common, Function}
    alias Igniter.Project.{Application, TaskAliases}
    alias Igniter.Project.Config, as: ProjectConfig
    alias Rekindle.{Config, Integration}
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
               config: config,
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

    defp select(_requested, nil, true),
      do: {:error, "client/Cargo.toml already exists; Rekindle will not overwrite it"}

    defp select(requested, existing, true) do
      with :ok <- same_or_omitted(:integration, requested.integration, existing.integration) do
        select_existing_targets(requested.targets, existing)
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

    defp select_existing_targets(nil, existing), do: {:ok, existing, :existing}

    defp select_existing_targets(targets, %{targets: targets} = existing),
      do: {:ok, existing, :existing}

    defp select_existing_targets(requested, existing) do
      if MapSet.subset?(MapSet.new(existing.targets), MapSet.new(requested)) do
        added = requested -- existing.targets
        {:ok, %{existing | targets: requested}, {:extend, added}}
      else
        same_or_omitted(:targets, requested, existing.targets)
      end
    end

    defp validate_generated_paths(igniter, selection, :generate) do
      generated_paths =
        selection.integration
        |> Integration.render(selection.targets)
        |> Map.keys()

      generated_paths
      |> Enum.find(&Igniter.exists?(igniter, Path.join("client", &1)))
      |> case do
        nil -> {:ok, :generate}
        path -> {:error, "client/#{path} already exists; Rekindle will not overwrite it"}
      end
    end

    defp validate_generated_paths(_igniter, _selection, :existing), do: {:ok, :existing}

    defp validate_generated_paths(igniter, _selection, {:extend, targets}) do
      manifest = content(igniter, "client/Cargo.toml")

      with {:ok, package_name} <- package_name(manifest),
           :ok <- validate_manifest_targets(manifest, targets) do
        {:ok, {:extend, targets, package_name}}
      end
    end

    defp install(igniter, app, endpoint, selection, mode, phoenix) do
      igniter
      |> maybe_generate_client(selection, mode)
      |> configure(app, selection)
      |> Application.add_new_child(
        {Rekindle,
         {:code,
          Sourceror.parse_string!("[otp_app: #{inspect(app)}, endpoint: #{inspect(endpoint)}]")}}
      )
      |> PhoenixInstall.install(app, endpoint, selection, phoenix)
      |> update_setup_aliases()
      |> maybe_add_web_alias(selection.targets)
      |> TaskAliases.add_alias(:precommit, "rekindle.check", if_exists: :append)
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
      |> TaskAliases.add_alias(:"assets.setup", "rekindle.setup", if_exists: :append)
    end

    defp maybe_generate_client(igniter, _selection, :existing), do: igniter

    defp maybe_generate_client(igniter, selection, :generate) do
      selection.integration
      |> Integration.render(selection.targets)
      |> Enum.reduce(igniter, fn {relative, contents}, igniter ->
        Igniter.create_new_file(igniter, Path.join("client", relative), contents)
      end)
      |> Igniter.mkdir("client/public")
    end

    defp maybe_generate_client(igniter, selection, {:extend, targets, package_name}) do
      targets
      |> Enum.reduce(igniter, fn target, igniter ->
        path = "src/bin/#{target}.rs"

        contents =
          selection.integration
          |> Integration.render([target], package_name: package_name)
          |> Map.fetch!(path)

        Igniter.create_new_file(igniter, Path.join("client", path), contents, on_exists: :skip)
      end)
      |> update_manifest_targets(targets)
    end

    defp configure(igniter, app, selection) when not is_map_key(selection, :config) do
      targets = Enum.map(selection.targets, &{&1, []})

      ProjectConfig.configure_new(
        igniter,
        "config.exs",
        app,
        [Rekindle],
        integration: selection.integration,
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

    defp update_manifest_targets(igniter, targets) do
      Igniter.create_or_update_file(igniter, "client/Cargo.toml", "", fn source ->
        manifest = Rewrite.Source.get(source, :content)

        missing =
          targets
          |> Enum.reject(&manifest_target?(manifest, &1))
          |> Enum.map(&manifest_target/1)

        updated =
          case missing do
            [] ->
              manifest

            blocks ->
              IO.iodata_to_binary([
                String.trim_trailing(manifest),
                "\n\n",
                Enum.intersperse(blocks, "\n")
              ])
          end

        Rewrite.Source.update(source, :content, updated)
      end)
    end

    defp manifest_target?(manifest, target) do
      Enum.any?(manifest_bin_blocks(manifest), &bin_name?(&1, target))
    end

    defp manifest_target(target) do
      """
      [[bin]]
      name = "#{target}"
      path = "src/bin/#{target}.rs"
      required-features = ["#{target}"]
      """
    end

    defp package_name(manifest) do
      with [_, package] <- Regex.run(~r/^\[package\]\s*$\n(.*?)(?=^\[|\z)/ms, manifest),
           [_, name] <-
             Regex.run(~r/^name\s*=\s*["']([^"']+)["']\s*(?:#.*)?$/m, package) do
        {:ok, name}
      else
        _ -> {:error, "client/Cargo.toml must contain a static package name"}
      end
    end

    defp validate_manifest_targets(manifest, targets) do
      Enum.reduce_while(targets, :ok, fn target, :ok ->
        case Enum.filter(manifest_bin_blocks(manifest), &bin_name?(&1, target)) do
          [] ->
            {:cont, :ok}

          [block] ->
            if canonical_bin?(block, target) do
              {:cont, :ok}
            else
              {:halt,
               {:error,
                "client/Cargo.toml already defines #{target} with a non-canonical bin configuration"}}
            end

          _duplicates ->
            {:halt, {:error, "client/Cargo.toml defines #{target} more than once"}}
        end
      end)
    end

    defp manifest_bin_blocks(manifest) do
      manifest
      |> String.split("[[bin]]")
      |> Enum.drop(1)
      |> Enum.map(&(&1 |> String.split(~r/^\[/m, parts: 2) |> hd()))
    end

    defp bin_name?(block, target), do: toml_string_field?(block, "name", Atom.to_string(target))

    defp canonical_bin?(block, target) do
      name = Atom.to_string(target)

      toml_string_field?(block, "path", "src/bin/#{name}.rs") and
        Regex.match?(
          ~r/^required-features\s*=\s*\[\s*["']#{name}["']\s*\]\s*(?:#.*)?$/m,
          block
        )
    end

    defp toml_string_field?(block, field, value) do
      Regex.match?(~r/^#{field}\s*=\s*["']#{Regex.escape(value)}["']\s*(?:#.*)?$/m, block)
    end

    defp content(igniter, path) do
      igniter.rewrite
      |> Rewrite.source!(path)
      |> Rewrite.Source.get(:content)
    end

    defp maybe_add_web_alias(igniter, targets) do
      if :web in targets do
        igniter
        |> TaskAliases.add_alias(:"assets.build", "rekindle.build web", if_exists: :append)
        |> TaskAliases.add_alias(
          :"assets.deploy",
          "rekindle.build web --release",
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
