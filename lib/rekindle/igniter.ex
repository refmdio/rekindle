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
      accepted_origins = Keyword.get(options, :accepted_origins, :endpoint)

      {igniter, endpoint} =
        resolve_endpoint(igniter, Keyword.get(options, :endpoint), :web in targets)

      igniter
      |> install_client(client_path, application_id, targets, options)
      |> install_config(
        otp_app,
        application_id,
        client_path,
        targets,
        endpoint,
        accepted_origins
      )
      |> install_child(otp_app)
      |> install_phoenix_endpoint(otp_app, endpoint, :web in targets)
      |> install_static_allowlist(endpoint, :web in targets)
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

      malformed_rekindle? =
        Enum.any?(value, fn entry ->
          entry != "rekindle.phoenix.deploy" and
            alias_command_reference?(entry, "rekindle.phoenix.deploy")
        end)

      cond do
        malformed_rekindle? ->
          {:error, "assets.deploy contains a foreign or malformed Rekindle deploy step"}

        digest_indices != [] and rekindle_indices != [] ->
          {:error, "assets.deploy mixes phx.digest with a Rekindle deploy step"}

        length(rekindle_indices) > 1 ->
          {:error, "assets.deploy contains multiple Rekindle deploy steps"}

        rekindle_indices != [] and rekindle_indices != [length(value) - 1] ->
          {:error, "assets.deploy Rekindle deploy step must be terminal"}

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

    @spec transform_assets_build(term()) :: {:ok, list()} | {:error, String.t()}
    def transform_assets_build({:__block__, _meta, [value]}), do: transform_assets_build(value)

    def transform_assets_build(value) when is_list(value) do
      owned_indices =
        value
        |> Enum.with_index()
        |> Enum.filter(fn {entry, _index} -> entry == "rekindle.build web" end)
        |> Enum.map(&elem(&1, 1))

      malformed_rekindle? =
        Enum.any?(value, fn entry ->
          entry != "rekindle.build web" and alias_command_reference?(entry, "rekindle.build")
        end)

      cond do
        malformed_rekindle? ->
          {:error, "assets.build contains a foreign or malformed Rekindle build step"}

        length(owned_indices) > 1 ->
          {:error, "assets.build contains multiple Rekindle build steps"}

        owned_indices != [] and owned_indices != [length(value) - 1] ->
          {:error, "assets.build Rekindle build step must be terminal"}

        owned_indices == [length(value) - 1] ->
          {:ok, value}

        true ->
          {:ok, value ++ ["rekindle.build web"]}
      end
    end

    def transform_assets_build(_value),
      do: {:error, "assets.build must be a literal task list"}

    defp install_client(igniter, client_path, application_id, targets, options) do
      if Keyword.get(options, :no_client, false) do
        validate_adopted_client(igniter, client_path, application_id, targets)
      else
        generate_client(igniter, client_path, application_id, targets)
      end
    end

    defp validate_adopted_client(igniter, client_path, application_id, targets) do
      marker = Path.join(client_path, ".rekindle-client.json")

      if Igniter.exists?(igniter, marker) and
           adoptable_marker?(igniter, client_path, marker, application_id, targets),
         do: igniter,
         else:
           Igniter.add_issue(
             igniter,
             "--no-client requires a structurally adoptable #{marker} for #{application_id}"
           )
    end

    defp generate_client(igniter, client_path, application_id, targets) do
      lock_path = Path.join(client_path, "Cargo.lock")
      generate_lock? = not Igniter.exists?(igniter, lock_path)

      files =
        ClientGenerator.render(
          application_id: application_id,
          package: application_id <> "_ui",
          web_binary: application_id <> "-web",
          desktop_binary: application_id,
          targets: targets
        )

      igniter =
        Enum.reduce(files, igniter, fn {relative, contents}, acc ->
          path = Path.join(client_path, relative)

          if relative in ["Cargo.lock", "src/app.rs", "public/.gitkeep"] and
               Igniter.exists?(acc, path) do
            acc
          else
            create_owned_file(acc, path, contents)
          end
        end)

      if generate_lock?,
        do: Igniter.add_task(igniter, "rekindle.client.lock", [client_path]),
        else: igniter
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

    defp install_config(
           igniter,
           otp_app,
           application_id,
           client_path,
           targets,
           endpoint,
           accepted_origins
         ) do
      build_targets =
        Enum.map(targets, fn
          :web ->
            {:web,
             [
               package: application_id <> "_ui",
               binary: application_id <> "-web",
               toolchain: [kind: :rustup, name: "nightly-2026-04-01"],
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
      |> maybe_configure_endpoint(endpoint, accepted_origins, :web in targets)
    end

    defp maybe_configure_endpoint(igniter, endpoint, accepted_origins, true)
         when is_atom(endpoint) do
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
        accepted_origins
      )
    end

    defp maybe_configure_endpoint(igniter, _endpoint, _accepted_origins, false), do: igniter

    defp maybe_configure_endpoint(igniter, _endpoint, _accepted_origins, true) do
      Igniter.add_issue(igniter, "Web installation requires one selected Phoenix endpoint")
    end

    defp resolve_endpoint(igniter, _requested, false), do: {igniter, nil}

    defp resolve_endpoint(igniter, requested, true) do
      {igniter, endpoints} =
        Igniter.Project.Module.find_all_matching_modules(igniter, fn _module, zipper ->
          Igniter.Code.Module.move_to_use(zipper, Phoenix.Endpoint) != :error
        end)

      endpoint =
        case requested do
          nil when length(endpoints) == 1 ->
            List.first(endpoints)

          nil ->
            nil

          module when is_atom(module) ->
            Enum.find(endpoints, &(&1 == module))

          text when is_binary(text) ->
            Enum.find(endpoints, &(inspect(&1) == text))

          _ ->
            nil
        end

      cond do
        endpoint ->
          {igniter, endpoint}

        is_nil(requested) and endpoints == [] ->
          {Igniter.add_issue(igniter, "Web installation requires one Phoenix endpoint"), nil}

        is_nil(requested) ->
          modules = endpoints |> Enum.map(&inspect/1) |> Enum.sort() |> Enum.join(", ")

          {Igniter.add_issue(
             igniter,
             "multiple Phoenix endpoints found (#{modules}); pass --endpoint MODULE"
           ), nil}

        true ->
          {Igniter.add_issue(
             igniter,
             "--endpoint must match a Phoenix endpoint discovered in this project"
           ), nil}
      end
    end

    defp install_phoenix_endpoint(igniter, _otp_app, _endpoint, false), do: igniter
    defp install_phoenix_endpoint(igniter, _otp_app, nil, true), do: igniter

    defp install_phoenix_endpoint(igniter, otp_app, endpoint, true) do
      block = endpoint_block(otp_app)

      case Igniter.Project.Module.find_and_update_module(igniter, endpoint, fn zipper ->
             source = Macro.to_string(Sourceror.Zipper.node(zipper))

             cond do
               endpoint_block_present?(source, otp_app) ->
                 {:ok, zipper}

               endpoint_owned_reference?(source) ->
                 {:error,
                  "the selected endpoint contains a conflicting Rekindle development registration"}

               true ->
                 case Function.move_to_function_call_in_current_scope(
                        zipper,
                        :plug,
                        [1, 2],
                        &router_plug?/1
                      ) do
                   {:ok, router} -> {:ok, Common.add_code(router, block, placement: :before)}
                   :error -> {:ok, Common.add_code(zipper, block)}
                 end
             end
           end) do
        {:ok, igniter} ->
          igniter

        {:error, igniter} ->
          Igniter.add_issue(igniter, "could not update selected Phoenix endpoint")
      end
    end

    defp endpoint_block(otp_app) do
      """
      if code_reloading? do
        socket "/_rekindle/socket", Rekindle.Phoenix.Socket,
          websocket: true,
          longpoll: false

        plug Rekindle.Phoenix.DevPlug, otp_app: #{inspect(otp_app)}
      end
      """
    end

    defp endpoint_block_present?(source, otp_app) do
      expected =
        otp_app
        |> endpoint_block()
        |> Code.string_to_quoted!()
        |> Macro.to_string()

      parsed = Code.string_to_quoted!(source)

      {_parsed, matches} =
        Macro.prewalk(parsed, 0, fn
          {:if, _, _} = node, matches ->
            increment = if Macro.to_string(node) == expected, do: 1, else: 0
            {node, matches + increment}

          node, matches ->
            {node, matches}
        end)

      matches == 1 and
        count(source, "Rekindle.Phoenix.Socket") == 1 and
        count(source, "Rekindle.Phoenix.DevPlug") == 1 and
        count(source, "\"/_rekindle/socket\"") == 1 and
        String.contains?(source, "otp_app: #{inspect(otp_app)}")
    rescue
      _ -> false
    end

    defp endpoint_owned_reference?(source) do
      String.contains?(source, "Rekindle.Phoenix.Socket") or
        String.contains?(source, "Rekindle.Phoenix.DevPlug") or
        String.contains?(source, "/_rekindle/")
    end

    defp router_plug?(%{node: {:plug, _, [module | _]}}) do
      module
      |> Macro.to_string()
      |> String.ends_with?("Router")
    end

    defp router_plug?(_zipper), do: false

    defp install_static_allowlist(igniter, _endpoint, false), do: igniter
    defp install_static_allowlist(igniter, nil, true), do: igniter

    defp install_static_allowlist(igniter, endpoint, true) do
      web_module = endpoint |> Module.split() |> Enum.drop(-1) |> Module.concat()

      case Igniter.Project.Module.find_and_update_module(igniter, web_module, fn zipper ->
             with {:ok, zipper} <-
                    Function.move_to_def(zipper, :static_paths, 0, target: :at),
                  {:ok, paths} <- static_paths_literal(Sourceror.Zipper.node(zipper)),
                  true <- Enum.all?(paths, &is_binary/1) do
               case Enum.count(paths, &(&1 == "rekindle")) do
                 0 ->
                   replacement =
                     Sourceror.parse_string!(
                       "def static_paths, do: #{inspect(paths ++ ["rekindle"])}"
                     )

                   {:ok, Common.replace_code(zipper, replacement)}

                 1 ->
                   {:ok, zipper}

                 _ ->
                   {:error, "static_paths/0 contains duplicate rekindle entries"}
               end
             else
               _ -> {:error, "static_paths/0 must return a literal top-level path list"}
             end
           end) do
        {:ok, igniter} ->
          igniter

        {:error, igniter} ->
          Igniter.add_issue(igniter, "could not update the Phoenix static path allowlist")
      end
    end

    defp static_paths_literal({:def, _, [_, clauses]}) when is_list(clauses) do
      clauses
      |> Enum.find_value(fn
        {:do, body} -> body
        {{:__block__, _, [:do]}, body} -> body
        _ -> nil
      end)
      |> literal_static_paths()
    end

    defp static_paths_literal(_node), do: :error

    defp literal_static_paths({:sigil_w, _, _} = body) do
      {paths, _binding} = Code.eval_quoted(body)
      if is_list(paths), do: {:ok, paths}, else: :error
    rescue
      _ -> :error
    end

    defp literal_static_paths(body) do
      with {:ok, quoted} <- body |> Sourceror.to_string() |> Code.string_to_quoted(),
           true <- Macro.quoted_literal?(quoted) do
        {paths, _binding} = Code.eval_quoted(quoted)
        if is_list(paths), do: {:ok, paths}, else: :error
      else
        _ -> :error
      end
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
          branch = child_branch(otp_app, child_name)

          case classify_child_node(node, branch) do
            :owned ->
              {:ok, zipper}

            :absent ->
              if match?({:ok, value} when is_list(value), Common.expand_literal(zipper)) do
                {:ok, base_children} = Common.expand_literal(zipper)
                {:ok, Common.replace_code(zipper, {:++, [], [base_children, branch]})}
              else
                {:error,
                 "application children must be a literal list or recognized Rekindle form"}
              end

            {:error, message} ->
              {:error, message}
          end
        else
          _ -> {:error, "could not find the application children list"}
        end
      end)
    end

    defp install_aliases(igniter, false), do: igniter

    defp install_aliases(igniter, true) do
      issue_count = mix_source_issue_count(igniter)

      validated =
        igniter
        |> validate_alias(:"assets.build", &transform_assets_build/1)
        |> validate_alias(:"assets.deploy", &transform_assets_deploy/1)

      if mix_source_issue_count(validated) > issue_count do
        validated
      else
        validated
        |> append_web_build()
        |> replace_phoenix_deploy()
      end
    end

    defp validate_alias(igniter, name, transform) do
      TaskAliases.modify_existing_alias(igniter, name, fn zipper ->
        with {:ok, value} <- Common.expand_literal(zipper),
             {:ok, _updated} <- transform.(value) do
          {:ok, zipper}
        else
          :error -> {:error, "#{name} must be a literal task list"}
          {:error, message} -> {:error, message}
        end
      end)
    end

    defp replace_phoenix_deploy(igniter) do
      TaskAliases.modify_existing_alias(igniter, :"assets.deploy", fn zipper ->
        {:ok, value} = Common.expand_literal(zipper)
        {:ok, updated} = transform_assets_deploy(value)
        {:ok, Common.replace_code(zipper, updated)}
      end)
    end

    defp mix_source_issue_count(igniter) do
      case Rewrite.source(igniter.rewrite, "mix.exs") do
        {:ok, source} -> source |> Rewrite.Source.issues() |> length()
        {:error, _reason} -> 0
      end
    end

    defp append_web_build(igniter) do
      TaskAliases.modify_existing_alias(igniter, :"assets.build", fn zipper ->
        with {:ok, value} <- Common.expand_literal(zipper),
             {:ok, updated} <- transform_assets_build(value) do
          {:ok, Common.replace_code(zipper, updated)}
        else
          :error -> {:error, "assets.build must be a literal task list"}
          {:error, message} -> {:error, message}
        end
      end)
    end

    defp child_branch(otp_app, child_name) do
      Sourceror.parse_string!("""
      if Code.ensure_loaded?(Mix) and Mix.env() != :prod do
        [{Rekindle, otp_app: #{inspect(otp_app)}, name: #{inspect(child_name)}}]
      else
        []
      end
      """)
    end

    defp classify_child_node(node, branch) do
      normalized = normalize_ast(node)
      expected_branch = normalize_ast(branch)

      case normalized do
        {:++, [], [base, ^expected_branch]} ->
          if not Macro.quoted_literal?(base) or rekindle_reference?(base) do
            {:error, "application children contain multiple or foreign Rekindle child forms"}
          else
            :owned
          end

        _ ->
          if rekindle_reference?(normalized) do
            {:error, "application children contain a foreign or malformed Rekindle child form"}
          else
            :absent
          end
      end
    end

    defp normalize_ast(ast) do
      Macro.prewalk(ast, fn
        {:__block__, _meta, [value]} -> value
        {form, meta, arguments} when is_list(meta) -> {form, [], arguments}
        node -> node
      end)
    end

    defp rekindle_reference?(ast) do
      {_ast, found?} =
        Macro.prewalk(ast, false, fn
          {:__aliases__, _meta, [:Rekindle | _]} = node, _found -> {node, true}
          module, found when is_atom(module) -> {module, found or rekindle_module_atom?(module)}
          node, found -> {node, found}
        end)

      found?
    end

    defp rekindle_module_atom?(module) do
      name = Atom.to_string(module)
      name == "Elixir.Rekindle" or String.starts_with?(name, "Elixir.Rekindle.")
    end

    defp alias_command_reference?(entry, command) when is_binary(entry) do
      entry
      |> String.split(~r/\s+/, trim: true)
      |> Enum.member?(command)
    end

    defp alias_command_reference?(_entry, _command), do: false

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

    defp adoptable_marker?(igniter, client_path, path, application_id, targets) do
      contents = read_file(igniter, path)
      target_names = Enum.map(targets, &Atom.to_string/1)
      package = application_id <> "_ui"
      web_binary = application_id <> "-web"
      desktop_binary = application_id

      with {:ok,
            %{
              "schema" => 1,
              "application_id" => ^application_id,
              "package" => ^package,
              "web_binary" => ^web_binary,
              "desktop_binary" => ^desktop_binary,
              "targets" => ^target_names,
              "owned_files" => owned_files
            }}
           when is_list(owned_files) <- Jason.decode(contents),
           expected <-
             ClientGenerator.render(
               application_id: application_id,
               package: package,
               web_binary: web_binary,
               desktop_binary: desktop_binary,
               targets: targets
             ),
           true <- Map.fetch!(expected, ".rekindle-client.json") == contents,
           true <- owned_files_valid?(igniter, client_path, owned_files),
           app when is_binary(app) <- read_file(igniter, Path.join(client_path, "src/app.rs")),
           true <- String.trim(app) != "",
           true <- source_directory?(igniter, Path.join(client_path, "public")) do
        true
      else
        _ -> false
      end
    rescue
      _ -> false
    end

    defp owned_files_valid?(igniter, client_path, entries) do
      entries != [] and
        Enum.all?(entries, fn
          %{"path" => ".rekindle-client.json", "template_sha256" => digest} ->
            valid_sha256?(digest)

          %{"path" => relative, "template_sha256" => digest}
          when is_binary(relative) and is_binary(digest) ->
            path = Path.join(client_path, relative)

            valid_sha256?(digest) and Igniter.exists?(igniter, path) and
              sha256(read_file(igniter, path)) == digest

          _ ->
            false
        end)
    end

    defp valid_sha256?(value),
      do: is_binary(value) and byte_size(value) == 64 and value =~ ~r/\A[0-9a-f]{64}\z/

    defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

    defp read_file(igniter, path) do
      case Rewrite.source(igniter.rewrite, path) do
        {:ok, source} ->
          Rewrite.Source.get(source, :content)

        {:error, _} when is_map_key(igniter.assigns, :test_files) ->
          Map.fetch!(igniter.assigns.test_files, path)

        _ ->
          File.read!(path)
      end
    end

    defp source_directory?(igniter, path) do
      prefix = String.trim_trailing(path, "/") <> "/"

      File.dir?(path) or
        Enum.any?(Rewrite.sources(igniter.rewrite), &String.starts_with?(&1.path, prefix)) or
        (is_map_key(igniter.assigns, :test_files) and
           Enum.any?(Map.keys(igniter.assigns.test_files), &String.starts_with?(&1, prefix)))
    end

    defp count(value, pattern),
      do: value |> String.split(pattern) |> length() |> Kernel.-(1)
  end
end
