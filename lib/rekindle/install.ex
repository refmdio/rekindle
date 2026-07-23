if Code.ensure_loaded?(Igniter) do
  defmodule Rekindle.Install do
    @moduledoc false

    alias Igniter.Code.{Common, Function}
    alias Igniter.Project.{Application, Config, TaskAliases}
    alias Rekindle.Integration

    @integrations Integration.names()
    @targets [:web, :desktop]

    @spec run(Igniter.t(), keyword()) :: Igniter.t()
    def run(igniter, options) do
      app = Application.app_name(igniter)

      with {:ok, requested} <- requested_selection(options),
           {:ok, existing} <- existing_selection(igniter, app),
           {:ok, selection, install?} <-
             select(requested, existing, Igniter.exists?(igniter, "client/Cargo.toml")),
           :ok <- available_paths(igniter, selection, install?) do
        install(igniter, app, selection, install?)
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
               true <- Keyword.keyword?(config),
               integration when integration in @integrations <- Keyword.get(config, :integration),
               targets when is_list(targets) <- Keyword.get(config, :targets),
               true <- Keyword.keyword?(targets),
               true <- Keyword.keys(targets) != [],
               true <- Enum.all?(Keyword.keys(targets), &(&1 in @targets)) do
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

    defp select(requested, nil, false) do
      {:ok,
       %{
         integration: requested.integration || :gpui,
         targets: requested.targets || @targets
       }, true}
    end

    defp select(_requested, nil, true) do
      {:error,
       "client/Cargo.toml already exists; pass both --integration and --targets to adopt it"}
    end

    defp select(requested, existing, true) do
      with :ok <- same_or_omitted(:integration, requested.integration, existing.integration),
           :ok <- same_or_omitted(:targets, requested.targets, existing.targets) do
        {:ok, existing, false}
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

    defp available_paths(_igniter, _selection, false), do: :ok

    defp available_paths(igniter, selection, true) do
      selection.integration
      |> Integration.render(selection.targets)
      |> Map.keys()
      |> Enum.find(&Igniter.exists?(igniter, Path.join("client", &1)))
      |> case do
        nil -> :ok
        path -> {:error, "client/#{path} already exists; Rekindle will not overwrite it"}
      end
    end

    defp install(igniter, app, selection, install?) do
      igniter
      |> maybe_generate_client(selection, install?)
      |> configure(app, selection)
      |> Application.add_new_child(
        {Rekindle, {:code, Sourceror.parse_string!("[otp_app: #{inspect(app)}]")}}
      )
      |> TaskAliases.add_alias(:setup, "rekindle.setup", if_exists: :append)
      |> maybe_add_web_alias(selection.targets)
      |> update_ignores(selection.targets, install?)
    end

    defp maybe_generate_client(igniter, _selection, false), do: igniter

    defp maybe_generate_client(igniter, selection, true) do
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

      Config.configure_new(
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

    defp update_ignores(igniter, targets, generated?) do
      entries =
        ["/.rekindle/"] ++
          if(generated?, do: ["/client/target/"], else: []) ++
          if(:web in targets, do: ["/priv/static/rekindle/"], else: []) ++
          if(:desktop in targets, do: ["/dist/rekindle/"], else: [])

      Igniter.create_or_update_file(igniter, ".gitignore", "", fn source ->
        content = Rewrite.Source.get(source, :content)
        lines = String.split(content, "\n", trim: true)
        updated = (lines ++ entries) |> Enum.uniq() |> Enum.join("\n") |> Kernel.<>("\n")
        Rewrite.Source.update(source, :content, updated)
      end)
    end
  end
end
