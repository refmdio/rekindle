if Code.ensure_loaded?(Igniter) do
  defmodule Rekindle.Igniter do
    @moduledoc false

    require Igniter.Code.Function

    alias Igniter.Code.{Common, Function}
    alias Igniter.Project.{Application, Config, TaskAliases}
    alias Rekindle.ClientGenerator

    @spec install(Igniter.t(), keyword()) :: Igniter.t()
    def install(igniter, options \\ []) do
      otp_app = Application.app_name(igniter)
      application_id = Atom.to_string(otp_app)
      client_path = Keyword.get(options, :client_path, "client")
      targets = Keyword.get(options, :targets, [:web, :desktop])
      endpoint = Keyword.get(options, :endpoint, default_endpoint(igniter))

      igniter
      |> install_client(client_path, application_id, targets, options)
      |> install_config(otp_app, application_id, client_path, targets, endpoint)
      |> install_child(otp_app)
      |> install_aliases(:web in targets)
      |> install_page_marker(otp_app, endpoint, targets)
      |> install_ignores(client_path)
    end

    @spec transform_assets_deploy(term()) :: {:ok, list()} | {:error, String.t()}
    def transform_assets_deploy({:__block__, _meta, [value]}),
      do: transform_assets_deploy(value)

    def transform_assets_deploy(value) when is_list(value) do
      digest_indices =
        value
        |> Enum.with_index()
        |> Enum.filter(fn {entry, _index} -> entry == "phx.digest" end)
        |> Enum.map(&elem(&1, 1))

      rekindle_indices =
        value
        |> Enum.with_index()
        |> Enum.filter(fn {entry, _index} -> entry == "rekindle.phoenix.deploy" end)
        |> Enum.map(&elem(&1, 1))

      cond do
        digest_indices == [] and rekindle_indices == [length(value) - 1] ->
          {:ok, value}

        digest_indices == [] ->
          {:error, "assets.deploy must contain one terminal phx.digest"}

        length(digest_indices) != 1 ->
          {:error, "assets.deploy contains multiple phx.digest steps"}

        List.first(digest_indices) != length(value) - 1 ->
          {:error, "assets.deploy phx.digest must be terminal"}

        true ->
          {:ok, List.replace_at(value, -1, "rekindle.phoenix.deploy")}
      end
    end

    def transform_assets_deploy(_value),
      do: {:error, "assets.deploy must be a literal task list"}

    defp install_client(igniter, _client_path, _application_id, _targets, no_client: true),
      do: igniter

    defp install_client(igniter, client_path, application_id, targets, _options) do
      files =
        ClientGenerator.render(
          application_id: application_id,
          package: application_id <> "_ui",
          web_binary: application_id <> "-web",
          desktop_binary: application_id,
          targets: targets
        )

      Enum.reduce(files, igniter, fn {relative, contents}, acc ->
        path = Path.join(client_path, relative)

        if relative in ["src/app.rs", "public/.gitkeep"] and Igniter.exists?(acc, path) do
          acc
        else
          create_owned_file(acc, path, contents)
        end
      end)
    end

    defp create_owned_file(igniter, path, contents) do
      if Igniter.exists?(igniter, path) do
        current =
          case Rewrite.source(igniter.rewrite, path) do
            {:ok, source} ->
              Rewrite.Source.get(source, :content)

            {:error, _reason} ->
              if(igniter.assigns[:test_mode?],
                do: igniter.assigns.test_files[path],
                else: File.read!(path)
              )
          end

        if current == contents do
          igniter
        else
          Igniter.add_issue(igniter, "Rekindle-owned client file conflicts: #{path}")
        end
      else
        Igniter.create_new_file(igniter, path, contents)
      end
    end

    defp install_config(igniter, otp_app, application_id, client_path, targets, endpoint) do
      build_targets =
        Enum.map(targets, fn
          :web ->
            {:web,
             [
               package: application_id <> "_ui",
               binary: application_id <> "-web",
               toolchain: [kind: :rustup, name: "1.95.0"],
               rust_target: "wasm32-unknown-unknown",
               features: ["web"],
               default_features: false,
               profiles: [dev: "dev", release: "release"],
               environment: [
                 inherit: :toolchain,
                 set: [],
                 unset: [],
                 build_inputs: [],
                 redact: []
               ],
               public: Path.join(client_path, "public"),
               hot_styles: [],
               projection: [mode: :phoenix_static, root: "priv/static/rekindle"]
             ]}

          :desktop ->
            {:desktop,
             [
               package: application_id <> "_ui",
               binary: application_id,
               toolchain: [kind: :rustup, name: "1.95.0"],
               features: ["desktop"],
               default_features: false,
               profiles: [dev: "dev", release: "release"],
               environment: [
                 inherit: :toolchain,
                 set: [],
                 unset: [],
                 build_inputs: [],
                 redact: []
               ],
               runtime: [
                 readiness: :ipc_v1,
                 startup_timeout_ms: 10_000,
                 shutdown_timeout_ms: 3_000,
                 replacement: :overlap,
                 handoff: :enabled
               ],
               projection: [mode: :directory, root: "dist/rekindle/desktop"]
             ]}
        end)

      dev_targets = if :web in targets, do: [:web], else: [:desktop]

      igniter
      |> Config.configure("config.exs", otp_app, [:rekindle_build, :schema], 1)
      |> Config.configure("config.exs", otp_app, [:rekindle_build, :client], client_path)
      |> Config.configure("config.exs", otp_app, [:rekindle_build, :targets], build_targets)
      |> Config.configure("dev.exs", otp_app, [:rekindle_dev, :schema], 1)
      |> Config.configure("dev.exs", otp_app, [:rekindle_dev, :enabled], true)
      |> Config.configure("dev.exs", otp_app, [:rekindle_dev, :targets], dev_targets)
      |> maybe_configure_endpoint(endpoint, :web in targets)
    end

    defp maybe_configure_endpoint(igniter, endpoint, true) when is_atom(endpoint) do
      igniter
      |> Config.configure(
        "dev.exs",
        Application.app_name(igniter),
        [:rekindle_dev, :endpoint],
        endpoint
      )
      |> Config.configure(
        "dev.exs",
        Application.app_name(igniter),
        [:rekindle_dev, :accepted_origins],
        :endpoint
      )
    end

    defp maybe_configure_endpoint(igniter, _endpoint, false), do: igniter

    defp maybe_configure_endpoint(igniter, _endpoint, true) do
      Igniter.add_issue(igniter, "Web installation requires one selected Phoenix endpoint")
    end

    defp install_child(igniter, otp_app) do
      child_name = Igniter.Project.Module.module_name(igniter, "Rekindle")
      application = Application.app_module(igniter)

      Igniter.Project.Module.find_and_update_module!(igniter, application, fn zipper ->
        with {:ok, zipper} <- Function.move_to_def(zipper, :start, 2),
             {:ok, zipper} <-
               Function.move_to_function_call_in_current_scope(
                 zipper,
                 :=,
                 [2],
                 fn call ->
                   Function.argument_matches_pattern?(
                     call,
                     0,
                     {:children, _, context} when is_atom(context)
                   )
                 end
               ),
             {:ok, zipper} <- Function.move_to_nth_argument(zipper, 1) do
          node = Sourceror.Zipper.node(zipper)

          cond do
            String.contains?(Macro.to_string(node), "Rekindle") ->
              {:ok, zipper}

            match?({:ok, value} when is_list(value), Common.expand_literal(zipper)) ->
              {:ok, base_children} = Common.expand_literal(zipper)

              branch =
                Sourceror.parse_string!("""
                if Code.ensure_loaded?(Mix) and Mix.env() != :prod do
                  [{Rekindle, otp_app: #{inspect(otp_app)}, name: #{inspect(child_name)}}]
                else
                  []
                end
                """)

              {:ok, Common.replace_code(zipper, {:++, [], [base_children, branch]})}

            true ->
              {:error, "application children must be a literal list or recognized Rekindle form"}
          end
        else
          _ -> {:error, "could not find the application children list"}
        end
      end)
    end

    defp install_aliases(igniter, web?) do
      igniter
      |> maybe_append_web_build(web?)
      |> TaskAliases.modify_existing_alias(:"assets.deploy", fn zipper ->
        with {:ok, value} <- Common.expand_literal(zipper),
             {:ok, updated} <- transform_assets_deploy(value) do
          {:ok, Common.replace_code(zipper, updated)}
        else
          :error -> {:error, "assets.deploy must be a literal task list"}
          {:error, message} -> {:error, message}
        end
      end)
    end

    defp maybe_append_web_build(igniter, false), do: igniter

    defp maybe_append_web_build(igniter, true) do
      TaskAliases.modify_existing_alias(igniter, :"assets.build", fn zipper ->
        case Common.expand_literal(zipper) do
          {:ok, value} when is_list(value) ->
            updated =
              if "rekindle.build web" in value, do: value, else: value ++ ["rekindle.build web"]

            {:ok, Common.replace_code(zipper, updated)}

          _ ->
            {:error, "assets.build must be a literal task list"}
        end
      end)
    end

    defp install_page_marker(igniter, otp_app, endpoint, targets) do
      layout = "lib/#{otp_app}_web/components/layouts/root.html.heex"

      if :web in targets and is_atom(endpoint) and Igniter.exists?(igniter, layout) do
        Igniter.update_file(igniter, layout, fn source ->
          contents = Rewrite.Source.get(source, :content)

          marker =
            "<Rekindle.Phoenix.Components.gpui_page otp_app={#{inspect(otp_app)}} endpoint={#{inspect(endpoint)}} />"

          cond do
            String.contains?(contents, marker) ->
              source

            length(Regex.scan(~r/data-rekindle-page|gpui_page/, contents)) > 0 ->
              {:error,
               "the selected root layout already contains a foreign GPUI/Rekindle page marker"}

            String.contains?(contents, "</body>") ->
              Rewrite.Source.update(
                source,
                :content,
                &String.replace(&1, "</body>", "  #{marker}\n</body>")
              )

            true ->
              {:error, "the selected root layout has no literal closing body tag"}
          end
        end)
      else
        igniter
      end
    end

    defp install_ignores(igniter, client_path) do
      paths = [
        "/.rekindle/",
        "/priv/static/rekindle/",
        "/dist/rekindle/desktop/",
        "/#{client_path}/.rekindle/"
      ]

      contents =
        case Rewrite.source(igniter.rewrite, ".gitignore") do
          {:ok, source} ->
            Rewrite.Source.get(source, :content)

          {:error, _} ->
            if igniter.assigns[:test_mode?] do
              igniter.assigns.test_files[".gitignore"] || ""
            else
              if(File.exists?(".gitignore"), do: File.read!(".gitignore"), else: "")
            end
        end

      updated =
        Enum.reduce(paths, contents, fn path, acc ->
          if path in String.split(acc, "\n"),
            do: acc,
            else: String.trim_trailing(acc) <> "\n" <> path <> "\n"
        end)

      source =
        contents
        |> Rewrite.Source.from_string(path: ".gitignore", owner: __MODULE__)
        |> Rewrite.Source.update(:content, fn _ -> updated end)

      %{igniter | rewrite: Rewrite.put!(igniter.rewrite, source)}
    end

    defp default_endpoint(igniter) do
      Igniter.Project.Module.module_name(igniter, "Web.Endpoint")
    end
  end
end
