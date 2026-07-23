if Code.ensure_loaded?(Igniter) do
  defmodule Rekindle.Install.Cargo do
    @moduledoc false

    alias Rekindle.Integration
    alias Rekindle.Toolchain.Process

    @platforms %{web: "wasm32-unknown-unknown"}

    @spec validate(Igniter.t(), Integration.name(), [Integration.target()]) ::
            {:ok, %{Integration.target() => keyword()}} | {:error, String.t()}
    def validate(igniter, integration, targets) do
      with_client_root(igniter, fn root ->
        with {:ok, platforms} <- platforms(targets) do
          targets
          |> Enum.reduce_while({:ok, %{}}, fn target, {:ok, resolved} ->
            with {:ok, metadata} <- metadata(root, Map.fetch!(platforms, target)),
                 {:ok, options} <- resolve(metadata, root, integration, target) do
              {:cont, {:ok, Map.put(resolved, target, options)}}
            else
              {:error, message} -> {:halt, {:error, message}}
            end
          end)
          |> require_one_package()
        end
      end)
    end

    defp with_client_root(igniter, callback) do
      root = temporary_root()

      try do
        :ok = copy_client(root)
        :ok = materialize(igniter, root)
        callback.(root)
      after
        File.rm_rf(root)
      end
    end

    defp copy_client(destination) do
      source = Path.expand("client")

      if File.dir?(source), do: copy_directory(source, destination), else: :ok
    end

    defp copy_directory(source, destination) do
      File.mkdir_p!(destination)

      source
      |> File.ls!()
      |> Enum.reject(&(&1 in ["target", ".git", ".rekindle"]))
      |> Enum.each(fn name ->
        source_path = Path.join(source, name)
        destination_path = Path.join(destination, name)

        cond do
          File.dir?(source_path) ->
            copy_directory(source_path, destination_path)

          File.regular?(source_path) ->
            File.mkdir_p!(Path.dirname(destination_path))
            File.cp!(source_path, destination_path)

          true ->
            raise "client contains an unsupported filesystem entry: #{source_path}"
        end
      end)
    end

    defp materialize(igniter, root) do
      igniter.rewrite.sources
      |> Enum.filter(fn {path, _source} -> String.starts_with?(path, "client/") end)
      |> Enum.each(fn {"client/" <> relative, source} ->
        path = Path.join(root, relative)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, Rewrite.Source.get(source, :content))
      end)
    end

    defp temporary_root do
      path =
        Path.join(
          System.tmp_dir!(),
          "rekindle-adopt-#{System.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir_p!(path)
      path
    end

    defp platforms(targets) do
      if :desktop in targets do
        case host_platform() do
          {:ok, platform} -> {:ok, Map.put(@platforms, :desktop, platform)}
          {:error, message} -> {:error, message}
        end
      else
        {:ok, @platforms}
      end
    end

    defp host_platform do
      rustc = System.find_executable("rustc") || "rustc"

      case Process.run(rustc, ["-vV"],
             cd: File.cwd!(),
             timeout: 30_000,
             output_limit: 16_000
           ) do
        {:ok, %{status: 0, output: output}} ->
          case Regex.run(~r/^host:\s+(\S+)$/m, output) do
            [_, platform] -> {:ok, platform}
            _ -> {:error, "rustc did not report its host platform"}
          end

        {:ok, result} ->
          {:error, "rustc host detection failed with status #{result.status}: #{result.output}"}

        {:error, reason} ->
          {:error, "rustc host detection failed: #{inspect(reason)}"}
      end
    end

    defp metadata(root, platform) do
      arguments = [
        "metadata",
        "--format-version",
        "1",
        "--filter-platform",
        platform,
        "--manifest-path",
        Path.join(root, "Cargo.toml")
      ]

      case Process.run(Rekindle.Toolchain.cargo_path(), arguments,
             cd: root,
             timeout: 120_000,
             output_limit: 8_000_000
           ) do
        {:ok, %{status: 0, truncated?: false, output: output}} ->
          metadata =
            output
            |> String.split("\n", trim: true)
            |> Enum.reverse()
            |> Enum.find_value(fn line ->
              case Jason.decode(line) do
                {:ok, %{"packages" => _packages} = metadata} -> metadata
                _ -> nil
              end
            end)

          case metadata do
            %{} -> {:ok, metadata}
            nil -> {:error, "cargo metadata returned invalid JSON"}
          end

        {:ok, %{truncated?: true}} ->
          {:error, "cargo metadata output exceeded the limit"}

        {:ok, result} ->
          {:error, "cargo metadata failed with status #{result.status}: #{result.output}"}

        {:error, reason} ->
          {:error, "cargo metadata could not run: #{inspect(reason)}"}
      end
    end

    defp resolve(metadata, root, selected, target) do
      workspace_members = MapSet.new(metadata["workspace_members"] || [])
      expected_entry = Path.expand("src/bin/#{target}.rs", root)

      candidates =
        metadata
        |> Map.get("packages", [])
        |> Enum.filter(&MapSet.member?(workspace_members, &1["id"]))
        |> Enum.flat_map(fn package ->
          package
          |> Map.get("targets", [])
          |> Enum.filter(fn candidate ->
            "bin" in (candidate["kind"] || []) and
              Path.expand(candidate["src_path"] || "") == expected_entry
          end)
          |> Enum.map(&{package, &1})
        end)

      case candidates do
        [{package, binary}] ->
          with :ok <- dependency(metadata, package, selected, target),
               {:ok, features} <- required_features(binary) do
            {:ok,
             [
               package: package["name"],
               binary: binary["name"],
               features: features
             ]}
          end

        [] ->
          {:error, "Cargo metadata has no binary for client/src/bin/#{target}.rs"}

        _ ->
          {:error, "Cargo metadata has multiple binaries for client/src/bin/#{target}.rs"}
      end
    end

    defp dependency(metadata, package, selected, target) do
      package_names = Map.new(metadata["packages"], &{&1["id"], &1["name"]})

      integrations =
        metadata
        |> get_in(["resolve", "nodes"])
        |> Enum.find(&(&1["id"] == package["id"]))
        |> Map.get("deps", [])
        |> Enum.flat_map(fn dependency ->
          case package_names[dependency["pkg"]] do
            "gpui" -> [:gpui]
            "eframe" -> [:egui]
            "slint" -> [:slint]
            _ -> []
          end
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
           "client/Cargo.toml has ambiguous UI framework dependencies for #{target}: #{Enum.join(found, ", ")}"}
      end
    end

    defp required_features(%{"required-features" => features}) when is_list(features) do
      if Enum.all?(features, &(is_binary(&1) and &1 != "")),
        do: {:ok, features},
        else: {:error, "Cargo metadata returned invalid required features"}
    end

    defp required_features(_binary), do: {:ok, []}

    defp require_one_package({:ok, resolved}) do
      packages =
        resolved
        |> Map.values()
        |> Enum.map(&Keyword.fetch!(&1, :package))
        |> Enum.uniq()

      case packages do
        [_package] -> {:ok, resolved}
        _ -> {:error, "selected target entries belong to different Cargo packages"}
      end
    end

    defp require_one_package(error), do: error
  end
end
