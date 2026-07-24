if Code.ensure_loaded?(Igniter) do
  defmodule Rekindle.Phoenix.Install do
    @moduledoc false

    alias Igniter.Code.{Common, Function}

    @spec endpoint(Igniter.t(), atom(), module(), map()) :: Igniter.t()
    def endpoint(igniter, app, endpoint, selection) do
      if :web in selection.targets do
        Igniter.Project.Module.find_and_update_module!(igniter, endpoint, fn zipper ->
          static_root = Path.join(selection.public_dir, "rekindle")

          additions =
            [
              unless(static_plug?(zipper, app, static_root),
                do: static_plug_source(app, static_root)
              ),
              unless(development_plug?(zipper), do: development_plug_source(app))
            ]
            |> Enum.reject(&is_nil/1)

          case additions do
            [] ->
              {:ok, zipper}

            additions ->
              case Igniter.Code.Module.move_to_use(zipper, Phoenix.Endpoint) do
                {:ok, use_zipper} ->
                  {:ok,
                   Common.add_code(use_zipper, Enum.join(additions, "\n\n"), placement: :after)}

                :error ->
                  {:error, "could not add the Rekindle endpoint plugs to #{inspect(endpoint)}"}
              end
          end
        end)
      else
        igniter
      end
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

    defp static_plug_options?(zipper, app, static_root) do
      with {:ok, options} <- Function.move_to_nth_argument(zipper, 1),
           {:ok, options} <- Common.expand_literal(options) do
        Keyword.get(options, :at) == "/rekindle" and
          Keyword.get(options, :from) == {app, static_root}
      else
        _error -> false
      end
    end

    defp development_plug?(zipper) do
      match?(
        {:ok, _zipper},
        Common.move_to(zipper, fn zipper ->
          Function.function_call?(zipper, :plug, 2) and
            Function.argument_equals?(zipper, 0, Rekindle.Phoenix.Development)
        end)
      )
    end

    defp static_plug_source(app, static_root) do
      """
      plug Plug.Static,
        at: "/rekindle",
        from: {#{inspect(app)}, #{inspect(static_root)}},
        gzip: false
      """
    end

    defp development_plug_source(app) do
      """
      if code_reloading? do
        plug Rekindle.Phoenix.Development, otp_app: #{inspect(app)}
      end
      """
    end
  end
end
