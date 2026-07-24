if Code.ensure_loaded?(Igniter) do
  defmodule Rekindle.Install.Cargo do
    @moduledoc false

    alias Rekindle.Integration
    alias Rekindle.Toolchain.Process

    @spec validate(Igniter.t(), Integration.name(), [Integration.target()]) ::
            {:ok, %{Integration.target() => keyword()}} | {:error, String.t()}
    def validate(igniter, integration, targets) do
      with_client_root(igniter, fn root, locked? ->
        with {:ok, platforms} <- platforms(targets) do
          targets
          |> Enum.reduce_while({:ok, %{}}, fn target, {:ok, resolved} ->
            platform = Map.fetch!(platforms, target)

            with {:ok, structure} <- metadata(root, platform, [], true, locked?),
                 {:ok, package, binary, features} <- target(structure, root, target),
                 {:ok, metadata} <- metadata(root, platform, features, false, locked?),
                 :ok <- dependency(metadata, package["id"], integration, target) do
              options = [
                package: package["name"],
                binary: binary["name"],
                features: features
              ]

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
      client_root = Path.expand("client")
      project_root = temporary_root()

      try do
        if File.regular?(Path.join(client_root, "Cargo.toml")) do
          copy_project(File.cwd!(), project_root)
        end

        :ok = materialize(igniter, project_root)
        callback.(Path.join(project_root, "client"), false)
      after
        File.rm_rf(project_root)
      end
    end

    defp materialize(igniter, project_root) do
      igniter.rewrite.sources
      |> Enum.each(fn {relative, source} ->
        path = Path.join(project_root, relative)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, Rewrite.Source.get(source, :content))
      end)
    end

    @snapshot_ignored [
      ".git",
      ".rekindle",
      "_build",
      "assets/node_modules",
      "client/target",
      "deps",
      "dist/rekindle",
      "priv/static/rekindle"
    ]

    defp copy_project(source, destination) do
      File.mkdir_p!(destination)
      copy_entries(source, destination, "", source, destination)
    end

    defp copy_entries(source, destination, relative, source_root, destination_root) do
      source
      |> File.ls!()
      |> Enum.each(fn name ->
        child_relative = Path.join(relative, name)

        unless child_relative in @snapshot_ignored do
          copy_entry(
            Path.join(source, name),
            Path.join(destination, name),
            child_relative,
            source_root,
            destination_root
          )
        end
      end)
    end

    defp copy_entry(source, destination, relative, source_root, destination_root) do
      case File.lstat!(source) do
        %{type: :directory, mode: mode} ->
          File.mkdir_p!(destination)
          File.chmod!(destination, mode)
          copy_entries(source, destination, relative, source_root, destination_root)

        %{type: :regular, mode: mode} ->
          File.mkdir_p!(Path.dirname(destination))
          File.cp!(source, destination)
          File.chmod!(destination, mode)

        %{type: :symlink} ->
          copy_symlink(source, destination, relative, source_root, destination_root)

        _other ->
          :ok
      end
    end

    defp copy_symlink(source, destination, relative, source_root, destination_root) do
      target = File.read_link!(source)
      resolved = Path.expand(target, Path.dirname(source))
      relative_target = Path.relative_to(resolved, source_root)

      if relative_target != ".." and not String.starts_with?(relative_target, "../") do
        snapshot_target = Path.join(destination_root, relative_target)
        copied_target = if Path.type(target) == :absolute, do: snapshot_target, else: target

        File.mkdir_p!(Path.dirname(destination))
        File.ln_s!(copied_target, destination)
      else
        copy_external_target(source, destination, relative, source_root, destination_root)
      end
    end

    defp copy_external_target(source, destination, relative, source_root, destination_root) do
      case File.stat!(source) do
        %{type: :directory, mode: mode} ->
          File.mkdir_p!(destination)
          File.chmod!(destination, mode)
          copy_entries(source, destination, relative, source_root, destination_root)

        %{type: :regular, mode: mode} ->
          File.mkdir_p!(Path.dirname(destination))
          File.cp!(source, destination)
          File.chmod!(destination, mode)
      end
    end

    defp temporary_root do
      name =
        "rekindle-adopt-" <> (:crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false))

      path = Path.join(System.tmp_dir!(), name)

      case File.mkdir(path) do
        :ok ->
          File.chmod!(path, 0o700)
          path

        {:error, :eexist} ->
          temporary_root()

        {:error, reason} ->
          raise File.Error, reason: reason, action: "create directory", path: path
      end
    end

    defp platforms(targets) do
      Enum.reduce_while(targets, {:ok, %{}}, fn target, {:ok, platforms} ->
        case Rekindle.Toolchain.target(target) do
          {:ok, platform} ->
            {:cont, {:ok, Map.put(platforms, target, platform)}}

          {:error, error} ->
            {:halt, {:error, Exception.message(error)}}
        end
      end)
    end

    defp metadata(root, platform, features, no_dependencies?, locked?) do
      arguments =
        [
          "metadata",
          "--format-version",
          "1",
          "--filter-platform",
          platform,
          "--manifest-path",
          Path.join(root, "Cargo.toml")
        ] ++
          if(no_dependencies?, do: ["--no-deps"], else: []) ++
          if(features == [], do: [], else: ["--features", Enum.join(features, ",")]) ++
          if(locked?, do: ["--locked"], else: [])

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

    defp target(metadata, root, target) do
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
          with {:ok, features} <- required_features(binary) do
            {:ok, package, binary, features}
          end

        [] ->
          {:error, "Cargo metadata has no binary for client/src/bin/#{target}.rs"}

        _ ->
          {:error, "Cargo metadata has multiple binaries for client/src/bin/#{target}.rs"}
      end
    end

    defp dependency(metadata, package_id, selected, target) do
      package_names = Map.new(metadata["packages"], &{&1["id"], &1["name"]})

      integrations =
        metadata
        |> get_in(["resolve", "nodes"])
        |> Enum.find(&(&1["id"] == package_id))
        |> Map.get("deps", [])
        |> Enum.filter(fn dependency ->
          Enum.any?(dependency["dep_kinds"] || [], &is_nil(&1["kind"]))
        end)
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
