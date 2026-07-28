if Code.ensure_loaded?(Igniter) do
  defmodule Rekindle.Phoenix.Install do
    @moduledoc false

    alias Igniter.Code.{Common, Function}
    alias Igniter.Project.Module, as: ProjectModule

    @type prepared :: %{
            layout_path: String.t(),
            layout_host: String.t(),
            layout_script: String.t()
          }

    @spec prepare(Igniter.t(), atom(), module(), map()) ::
            {:ok, Igniter.t(), prepared() | nil} | {:error, String.t()}
    def prepare(igniter, _app, endpoint, selection) do
      if :web in selection.targets do
        prepare_layout(igniter, endpoint, selection.integration)
      else
        {:ok, igniter, nil}
      end
    end

    @spec install(Igniter.t(), atom(), module(), map(), prepared() | nil) :: Igniter.t()
    def install(igniter, _app, _endpoint, _selection, nil), do: igniter

    def install(igniter, app, endpoint, _selection, prepared) do
      igniter
      |> install_endpoint(app, endpoint)
      |> install_layout(prepared)
    end

    defp prepare_layout(igniter, endpoint, integration) do
      layouts = Igniter.Libs.Phoenix.web_module_name(igniter, "Layouts")

      case ProjectModule.find_module(igniter, layouts) do
        {:ok, {igniter, source, _zipper}} ->
          path = Path.join([Path.dirname(source.path), "layouts", "root.html.heex"])
          igniter = Igniter.include_existing_file(igniter, path, required?: true)

          case Rewrite.source(igniter.rewrite, path) do
            {:ok, layout_source} ->
              {host, script} = layout_parts(endpoint, integration)
              content = Rewrite.Source.get(layout_source, :content)

              if missing_layout_parts(content, host, script) != [] and
                   not Regex.match?(~r{</body\s*>}i, content) do
                {:error, "#{path} must contain </body> so Rekindle can install its Web entry"}
              else
                {:ok, igniter, %{layout_path: path, layout_host: host, layout_script: script}}
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
           layout_script: script
         }) do
      Igniter.create_or_update_file(igniter, path, "", fn source ->
        content = Rewrite.Source.get(source, :content)

        updated =
          case missing_layout_parts(content, host, script) do
            [] ->
              content

            missing ->
              block = Enum.join(missing, "\n")

              Regex.replace(
                ~r{([ \t]*)</body\s*>}i,
                content,
                fn closing, indentation ->
                  indent_block(block, indentation <> "  ") <> "\n" <> closing
                end,
                global: false
              )
          end

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

    defp layout_parts(endpoint, integration) do
      host = Rekindle.Integration.host(integration)

      script =
        ~s|<script type="module" src={Rekindle.Phoenix.web_entry_path(#{inspect(endpoint)})}></script>|

      {host, script}
    end

    defp missing_layout_parts(content, host, script) do
      [host, script]
      |> Enum.reject(&(&1 == "" or String.contains?(content, &1)))
    end

    defp indent_block(block, indentation) do
      block
      |> String.split("\n")
      |> Enum.map_join("\n", &(indentation <> &1))
    end
  end
end
