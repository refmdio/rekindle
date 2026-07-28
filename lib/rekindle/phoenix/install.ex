if Code.ensure_loaded?(Igniter) do
  defmodule Rekindle.Phoenix.Install do
    @moduledoc false

    alias Igniter.Code.{Common, Function}
    alias Igniter.Project.Module, as: ProjectModule
    alias Igniter.Project.TaskAliases

    @type prepared :: %{
            layout_path: String.t(),
            layout_host: String.t(),
            layout_script: String.t(),
            layout_style: String.t()
          }

    @spec prepare(Igniter.t(), atom(), module(), map()) ::
            {:ok, Igniter.t(), prepared() | nil} | {:error, String.t()}
    def prepare(igniter, _app, endpoint, selection) do
      if :web in selection.targets do
        prepare_layout(igniter, endpoint, selection.plugin)
      else
        {:ok, igniter, nil}
      end
    end

    @spec install(Igniter.t(), atom(), module(), map(), prepared() | nil) :: Igniter.t()
    def install(igniter, _app, _endpoint, _selection, nil), do: igniter

    def install(igniter, app, endpoint, selection, prepared) do
      igniter
      |> install_endpoint(app, endpoint)
      |> install_layout(prepared)
      |> install_generated_page_test(prepared.layout_path, selection.plugin)
      |> install_build_aliases(selection.targets)
    end

    defp install_build_aliases(igniter, targets) do
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

    defp prepare_layout(igniter, endpoint, plugin) do
      layouts = Igniter.Libs.Phoenix.web_module_name(igniter, "Layouts")

      case ProjectModule.find_module(igniter, layouts) do
        {:ok, {igniter, source, _zipper}} ->
          path = Path.join([Path.dirname(source.path), "layouts", "root.html.heex"])
          igniter = Igniter.include_existing_file(igniter, path, required?: true)

          case Rewrite.source(igniter.rewrite, path) do
            {:ok, layout_source} ->
              {style, host, script} = layout_parts(endpoint, plugin)
              content = Rewrite.Source.get(layout_source, :content)

              cond do
                not style_present?(content, style) and
                    not Regex.match?(~r{</head\s*>}i, content) ->
                  {:error, "#{path} must contain </head> so Rekindle can install its Web style"}

                missing_body_parts(content, host, script) != [] and
                    not Regex.match?(~r{</body\s*>}i, content) ->
                  {:error, "#{path} must contain </body> so Rekindle can install its Web entry"}

                true ->
                  {:ok, igniter,
                   %{
                     layout_path: path,
                     layout_host: host,
                     layout_script: script,
                     layout_style: style
                   }}
              end

            {:error, %Rewrite.Error{} = error} ->
              {:error, Exception.message(error)}
          end

        {:error, _igniter} ->
          {:error, "could not find #{inspect(layouts)} while preparing the Rekindle Web host"}
      end
    end

    defp install_endpoint(igniter, app, endpoint) do
      ProjectModule.find_and_update_module!(igniter, endpoint, fn zipper ->
        with {:ok, zipper} <- maybe_add_static_plug(zipper, app),
             {:ok, zipper} <- maybe_add_development_plug(zipper, app) do
          {:ok, zipper}
        else
          :error -> {:error, "could not install the Rekindle endpoint Plugs"}
        end
      end)
    end

    defp maybe_add_static_plug(zipper, app) do
      if static_plug?(zipper, app) do
        {:ok, zipper}
      else
        case Igniter.Code.Module.move_to_use(zipper, Phoenix.Endpoint) do
          {:ok, use_zipper} ->
            {:ok, Common.add_code(use_zipper, static_plug_source(app), placement: :after)}

          :error ->
            :error
        end
      end
    end

    defp maybe_add_development_plug(zipper, app) do
      if development_plug?(zipper, app) do
        {:ok, zipper}
      else
        case Common.move_to(zipper, fn zipper ->
               Function.function_call?(zipper, :plug, 1) and
                 Function.argument_equals?(zipper, 0, Phoenix.CodeReloader)
             end) do
          {:ok, code_reloader} ->
            {:ok, Common.add_code(code_reloader, development_plug_source(app), placement: :after)}

          :error ->
            :error
        end
      end
    end

    defp install_layout(igniter, %{
           layout_path: path,
           layout_host: host,
           layout_script: script,
           layout_style: style
         }) do
      Igniter.create_or_update_file(igniter, path, "", fn source ->
        content = Rewrite.Source.get(source, :content)

        updated =
          content
          |> install_style(style)
          |> install_host(host)
          |> install_script(script)

        Rewrite.Source.update(source, :content, updated)
      end)
    end

    defp install_generated_page_test(igniter, layout_path, plugin) do
      web_root = layout_path |> Path.dirname() |> Path.dirname() |> Path.dirname()

      path =
        Path.join([
          "test",
          Path.basename(web_root),
          "controllers",
          "page_controller_test.exs"
        ])

      igniter = Igniter.include_existing_file(igniter, path)

      case Rewrite.source(igniter.rewrite, path) do
        {:ok, _source} -> rewrite_generated_page_test(igniter, path, plugin)
        {:error, _error} -> igniter
      end
    end

    defp rewrite_generated_page_test(igniter, path, plugin) do
      plugin_name = Rekindle.Plugin.name(plugin)

      Igniter.create_or_update_file(igniter, path, "", fn source ->
        content = Rewrite.Source.get(source, :content)

        updated =
          Regex.replace(
            ~r/^([ \t]*)assert html_response\(conn, 200\) =~ "Peace of mind from prototype to production"$/m,
            content,
            fn _match, indentation ->
              """
              #{indentation}response = html_response(conn, 200)

              #{indentation}assert response =~ ~s(data-rust-ui="#{plugin_name}")
              """
              |> String.trim_trailing()
            end,
            global: false
          )

        Rewrite.Source.update(source, :content, updated)
      end)
    end

    defp static_plug?(zipper, app) do
      match?(
        {:ok, _zipper},
        Common.move_to(zipper, fn zipper ->
          Function.function_call?(zipper, :plug, 2) and
            Function.argument_equals?(zipper, 0, Plug.Static) and
            static_plug_options?(zipper, app)
        end)
      )
    end

    defp static_plug_options?(zipper, app) do
      with {:ok, options} <- Function.move_to_nth_argument(zipper, 1),
           {:ok, options} <- Common.expand_literal(options) do
        Keyword.get(options, :at) == "/rekindle" and
          Keyword.get(options, :from) == {app, "priv/static/rekindle"}
      else
        _error -> false
      end
    end

    defp development_plug?(zipper, app) do
      match?(
        {:ok, _zipper},
        Common.move_to(zipper, fn zipper ->
          Function.function_call?(zipper, :plug, 2) and
            Function.argument_equals?(zipper, 0, Rekindle.DevServer) and
            development_plug_options?(zipper, app)
        end)
      )
    end

    defp development_plug_options?(zipper, app) do
      with {:ok, options} <- Function.move_to_nth_argument(zipper, 1),
           {:ok, options} <- Common.expand_literal(options) do
        Keyword.get(options, :otp_app) == app
      else
        _error -> false
      end
    end

    defp static_plug_source(app) do
      """
      plug Plug.Static,
        at: "/rekindle",
        from: {#{inspect(app)}, "priv/static/rekindle"},
        gzip: false
      """
    end

    defp development_plug_source(app),
      do: "plug Rekindle.DevServer, otp_app: #{inspect(app)}"

    defp layout_parts(endpoint, plugin) do
      spec = Rekindle.Plugin.spec(plugin)
      css = spec.web.style |> String.trim() |> indent_block("  ")

      host = spec.web.host

      style = "<style data-rust-ui=\"#{spec.name}\">\n#{css}\n</style>"

      script = """
      <script type="module" src={Rekindle.Phoenix.web_entry_path(#{inspect(endpoint)})}>
      </script>
      """

      {style, host, script}
    end

    defp missing_body_parts(content, host, script) do
      []
      |> maybe_missing(host != "" and not String.contains?(content, host), host)
      |> maybe_missing(not script_present?(content, script), script)
    end

    defp maybe_missing(missing, true, part), do: [part | missing]
    defp maybe_missing(missing, false, _part), do: missing

    defp install_style(content, style) do
      if style_present?(content, style) do
        content
      else
        insert_before_closing(content, ~r{([ \t]*)</head\s*>}i, style)
      end
    end

    defp style_present?(content, style),
      do: String.contains?(content, style |> String.split("\n", parts: 2) |> hd())

    defp install_host(content, host) do
      cond do
        String.contains?(content, host) and host != "" ->
          replace_inner_content(content, "")

        String.contains?(content, "{@inner_content}") ->
          replace_inner_content(content, host)

        host == "" ->
          content

        true ->
          insert_before_closing(content, ~r{([ \t]*)</body\s*>}i, host)
      end
    end

    defp install_script(content, script) do
      if script_present?(content, script) do
        content
      else
        insert_before_closing(content, ~r{([ \t]*)</body\s*>}i, script)
      end
    end

    defp script_present?(content, script),
      do: String.contains?(content, script_marker(script))

    defp script_marker(script) do
      [marker] = Regex.run(~r{Rekindle\.Phoenix\.web_entry_path\([^)]+\)}, script)
      marker
    end

    defp replace_inner_content(content, "") do
      String.replace(content, ~r{[ \t]*\{@inner_content\}[ \t]*\n?}, "", global: false)
    end

    defp replace_inner_content(content, host) do
      Regex.replace(
        ~r{([ \t]*)\{@inner_content\}[ \t]*},
        content,
        fn _match, indentation -> indent_block(host, indentation) end,
        global: false
      )
    end

    defp insert_before_closing(content, pattern, block) do
      Regex.replace(
        pattern,
        content,
        fn closing, indentation ->
          indent_block(String.trim_trailing(block), indentation <> "  ") <> "\n" <> closing
        end,
        global: false
      )
    end

    defp indent_block(block, indentation) do
      block
      |> String.split("\n")
      |> Enum.map_join("\n", fn
        "" -> ""
        line -> indentation <> line
      end)
    end
  end
end
