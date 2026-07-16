if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Rekindle.Install do
    @shortdoc "Install Rekindle into a Phoenix project"

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :rekindle,
        schema: [
          client_path: :string,
          targets: :csv,
          endpoint: :string,
          accepted_origin: :keep,
          no_client: :boolean
        ],
        defaults: [client_path: "client", targets: ["web", "desktop"], no_client: false],
        example: "mix igniter.install rekindle"
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options

      with {:ok, targets} <- parse_targets(options[:targets]),
           {:ok, endpoint} <- existing_endpoint(options[:endpoint]) do
        Rekindle.Igniter.install(igniter,
          client_path: options[:client_path],
          targets: targets,
          endpoint: endpoint,
          accepted_origins: accepted_origins(options[:accepted_origin]),
          no_client: options[:no_client]
        )
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp parse_targets(values) do
      targets =
        Enum.map(values || [], fn value ->
          if value == "web", do: :web, else: if(value == "desktop", do: :desktop, else: :invalid)
        end)

      if targets != [] and :invalid not in targets and Enum.uniq(targets) == targets do
        {:ok, targets}
      else
        {:error, "--targets must be web, desktop, or web,desktop without duplicates"}
      end
    end

    defp existing_endpoint(nil), do: {:ok, nil}

    defp existing_endpoint(text) do
      case Enum.find(:code.all_loaded(), fn {module, _path} -> inspect(module) == text end) do
        {module, _path} -> {:ok, module}
        nil -> {:error, "--endpoint must name an already loaded module"}
      end
    end

    defp accepted_origins(nil), do: :endpoint
    defp accepted_origins([]), do: :endpoint
    defp accepted_origins(values), do: values
  end
end
