if Code.ensure_loaded?(Igniter) do
  defmodule Rekindle.Phoenix.Install do
    @moduledoc false

    alias Igniter.Code.{Common, Function}
    alias Igniter.Project.Module, as: ProjectModule

    @type prepared :: %{
            layout_path: String.t(),
            layout_block: String.t(),
            layout_script: String.t()
          }

    @spec prepare(Igniter.t(), atom(), module(), map()) ::
            {:ok, Igniter.t(), prepared() | nil} | {:error, String.t()}
    def prepare(igniter, app, endpoint, selection) do
      if :web in selection.targets do
        with {:ok, igniter} <- preflight_endpoint(igniter, app, endpoint, selection),
             {:ok, igniter, layout} <- preflight_layout(igniter, endpoint, selection) do
          {:ok, igniter, layout}
        end
      else
        {:ok, igniter, nil}
      end
    end

    @spec install(Igniter.t(), atom(), module(), map(), prepared() | nil) :: Igniter.t()
    def install(igniter, _app, _endpoint, _selection, nil), do: igniter

    def install(igniter, app, endpoint, selection, prepared) do
      igniter
      |> install_endpoint(app, endpoint, selection)
      |> install_layout(prepared)
    end

    defp preflight_endpoint(igniter, app, endpoint, selection) do
      case ProjectModule.find_module(igniter, endpoint) do
        {:ok, {igniter, _source, zipper}} ->
          static_root = Path.join(selection.public_dir, "rekindle")

          with :ok <- validate_static_plug(zipper, app, static_root),
               :ok <- validate_development_plug(zipper, app) do
            {:ok, igniter}
          end

        {:error, igniter} ->
          {:error,
           "could not find #{inspect(endpoint)} while preparing the Rekindle Web integration" <>
             issues_suffix(igniter)}
      end
    end

    defp validate_static_plug(zipper, app, static_root) do
      plugs =
        Common.find_all(zipper, fn zipper ->
          Function.function_call?(zipper, :plug, 2) and
            Function.argument_equals?(zipper, 0, Plug.Static) and
            static_at_rekindle?(zipper)
        end)

      case plugs do
        [] ->
          :ok

        [plug] ->
          if static_plug_options?(plug, app, static_root) do
            :ok
          else
            {:error,
             "the existing Plug.Static mount at /rekindle does not match the configured Rekindle public directory"}
          end

        _plugs ->
          {:error, "the Phoenix endpoint contains duplicate Plug.Static mounts at /rekindle"}
      end
    end

    defp validate_development_plug(zipper, app) do
      code_reloaders =
        Common.find_all(zipper, fn zipper ->
          Function.function_call?(zipper, :plug, 1) and
            Function.argument_equals?(zipper, 0, Phoenix.CodeReloader)
        end)

      development_plugs =
        Common.find_all(zipper, fn zipper ->
          Function.function_call?(zipper, :plug, 2) and
            Function.argument_equals?(zipper, 0, Rekindle.Phoenix.Development)
        end)

      case {code_reloaders, development_plugs} do
        {[_code_reloader], []} ->
          :ok

        {[_code_reloader], [development]} ->
          if development_plug_options?(development, app) and
               immediately_after_code_reloader?(development) do
            :ok
          else
            {:error,
             "the existing Rekindle development Plug must follow Phoenix.CodeReloader and use the configured OTP application"}
          end

        {[], _development_plugs} ->
          {:error,
           "the Phoenix endpoint must contain one Phoenix.CodeReloader before Rekindle can install its development Plug"}

        {_code_reloaders, [_ | [_ | _]]} ->
          {:error, "the Phoenix endpoint contains duplicate Rekindle development Plugs"}

        {_code_reloaders, _development_plugs} ->
          {:error,
           "the Phoenix endpoint must contain exactly one Phoenix.CodeReloader for Rekindle Web development"}
      end
    end

    defp preflight_layout(igniter, endpoint, selection) do
      layouts = Igniter.Libs.Phoenix.web_module_name(igniter, "Layouts")

      case ProjectModule.find_module(igniter, layouts) do
        {:ok, {igniter, source, zipper}} ->
          with :ok <- validate_embedded_layouts(zipper, layouts),
               path = Path.join([Path.dirname(source.path), "layouts", "root.html.heex"]),
               igniter <- Igniter.include_existing_file(igniter, path, required?: true),
               {:ok, layout_source} <- Rewrite.source(igniter.rewrite, path),
               content = Rewrite.Source.get(layout_source, :content),
               {host, script} = layout_parts(endpoint, selection.integration),
               :ok <- validate_layout(content, host, script, selection.integration) do
            block = Enum.reject([host, script], &(&1 == "")) |> Enum.join("\n")
            {:ok, igniter, %{layout_path: path, layout_block: block, layout_script: script}}
          else
            {:error, %Rewrite.Error{} = error} -> {:error, Exception.message(error)}
            {:error, message} when is_binary(message) -> {:error, message}
          end

        {:error, igniter} ->
          {:error,
           "could not find #{inspect(layouts)} while preparing the Rekindle Web host" <>
             issues_suffix(igniter)}
      end
    end

    defp validate_embedded_layouts(zipper, layouts) do
      embeds =
        Common.find_all(zipper, fn zipper ->
          Function.function_call?(zipper, :embed_templates, 1) and
            Function.argument_equals?(zipper, 0, "layouts/*")
        end)

      if length(embeds) == 1 do
        :ok
      else
        {:error,
         "#{inspect(layouts)} must contain exactly one `embed_templates \"layouts/*\"` declaration"}
      end
    end

    defp validate_layout(content, host, script, integration) do
      closing_bodies = Regex.scan(~r{</body\s*>}i, content)
      entry_calls = Regex.scan(~r/Rekindle\.Phoenix\.web_entry_path\s*\(/, content)

      complete? =
        String.contains?(content, script) and (host == "" or String.contains?(content, host))

      cond do
        complete? and length(entry_calls) == 1 ->
          :ok

        entry_calls != [] ->
          {:error,
           "the Phoenix root layout contains a partial or mismatched Rekindle Web module script"}

        host != "" and host_id_collision?(content, host) ->
          {:error,
           "the Phoenix root layout already contains the DOM identifier required by the #{integration} integration"}

        length(closing_bodies) != 1 ->
          {:error, "the Phoenix root layout must contain exactly one closing body element"}

        true ->
          :ok
      end
    end

    defp host_id_collision?(content, host) do
      [id] = Regex.run(~r/\bid="([^"]+)"/, host, capture: :all_but_first)
      Regex.match?(~r/\bid\s*=\s*["']#{Regex.escape(id)}["']/, content)
    end

    defp install_endpoint(igniter, app, endpoint, selection) do
      ProjectModule.find_and_update_module!(igniter, endpoint, fn zipper ->
        static_root = Path.join(selection.public_dir, "rekindle")

        with {:ok, zipper} <- maybe_add_static_plug(zipper, app, static_root),
             {:ok, zipper} <- maybe_add_development_plug(zipper, app) do
          {:ok, zipper}
        else
          :error -> {:error, "could not install the Rekindle endpoint Plugs"}
        end
      end)
    end

    defp maybe_add_static_plug(zipper, app, static_root) do
      if static_plug?(zipper, app, static_root) do
        {:ok, zipper}
      else
        case Igniter.Code.Module.move_to_use(zipper, Phoenix.Endpoint) do
          {:ok, use_zipper} ->
            {:ok,
             Common.add_code(use_zipper, static_plug_source(app, static_root), placement: :after)}

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
           layout_block: block,
           layout_script: script
         }) do
      Igniter.create_or_update_file(igniter, path, "", fn source ->
        content = Rewrite.Source.get(source, :content)

        updated =
          if String.contains?(content, script) do
            content
          else
            Regex.replace(~r{([ \t]*)</body\s*>}i, content, fn closing, indentation ->
              indent_block(block, indentation <> "  ") <> "\n" <> closing
            end)
          end

        Rewrite.Source.update(source, :content, updated)
      end)
    end

    defp static_plug?(zipper, app, static_root) do
      match?(
        {:ok, _zipper},
        Common.move_to(zipper, fn zipper ->
          Function.function_call?(zipper, :plug, 2) and
            Function.argument_equals?(zipper, 0, Plug.Static) and
            static_plug_options?(zipper, app, static_root)
        end)
      )
    end

    defp static_at_rekindle?(zipper) do
      with {:ok, options} <- Function.move_to_nth_argument(zipper, 1),
           {:ok, options} <- Common.expand_literal(options) do
        Keyword.get(options, :at) == "/rekindle"
      else
        _error -> false
      end
    end

    defp static_plug_options?(zipper, app, static_root) do
      with {:ok, options} <- Function.move_to_nth_argument(zipper, 1),
           {:ok, options} <- Common.expand_literal(options) do
        Keyword.get(options, :at) == "/rekindle" and
          Keyword.get(options, :from) == {app, static_root}
      else
        _error -> false
      end
    end

    defp development_plug?(zipper, app) do
      match?(
        {:ok, _zipper},
        Common.move_to(zipper, fn zipper ->
          Function.function_call?(zipper, :plug, 2) and
            Function.argument_equals?(zipper, 0, Rekindle.Phoenix.Development) and
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

    defp immediately_after_code_reloader?(development) do
      case Common.find_prev(development, fn zipper ->
             zipper.node != development.node and
               (Function.function_call?(zipper, :plug, 1) or
                  Function.function_call?(zipper, :plug, 2))
           end) do
        {:ok, previous} -> Function.argument_equals?(previous, 0, Phoenix.CodeReloader)
        :error -> false
      end
    end

    defp static_plug_source(app, static_root) do
      """
      plug Plug.Static,
        at: "/rekindle",
        from: {#{inspect(app)}, #{inspect(static_root)}},
        gzip: false
      """
    end

    defp development_plug_source(app),
      do: "plug Rekindle.Phoenix.Development, otp_app: #{inspect(app)}"

    defp layout_parts(endpoint, integration) do
      host = Rekindle.Integration.host(integration)

      script =
        ~s|<script type="module" src={Rekindle.Phoenix.web_entry_path(#{inspect(endpoint)})}></script>|

      {host, script}
    end

    defp indent_block(block, indentation) do
      block
      |> String.split("\n")
      |> Enum.map_join("\n", &(indentation <> &1))
    end

    defp issues_suffix(%{issues: []}), do: ""
    defp issues_suffix(%{issues: issues}), do: ": " <> Enum.join(issues, "; ")
  end
end
