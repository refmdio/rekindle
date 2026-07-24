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

      with {:ok, project_root} <- temporary_root() do
        result =
          with :ok <- maybe_copy_project(client_root, project_root),
               :ok <- materialize(igniter, project_root) do
            callback.(Path.join(project_root, "client"), false)
          end

        case remove_snapshot(project_root) do
          :ok -> result
          {:error, _message} = error -> error
        end
      end
    end

    defp maybe_copy_project(client_root, project_root) do
      manifest = Path.join(client_root, "Cargo.toml")

      case File.lstat(manifest) do
        {:ok, %{type: type}} when type in [:regular, :symlink] ->
          case File.cwd() do
            {:ok, source} -> copy_project(source, project_root)
            {:error, reason} -> snapshot_error(".", "resolve application root", reason)
          end

        {:ok, _other} ->
          :ok

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          snapshot_error(manifest, "inspect client manifest", reason)
      end
    end

    defp materialize(igniter, project_root) do
      igniter.rewrite.sources
      |> Enum.reduce_while(:ok, fn {relative, source}, :ok ->
        path = Path.join(project_root, relative)

        with :ok <- file_operation(File.mkdir_p(Path.dirname(path)), path, "create directory"),
             :ok <-
               file_operation(
                 File.write(path, Rewrite.Source.get(source, :content)),
                 path,
                 "write file"
               ) do
          {:cont, :ok}
        else
          {:error, message} -> {:halt, {:error, message}}
        end
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
      with :ok <- file_operation(File.mkdir_p(destination), destination, "create directory") do
        copy_entries(source, destination, "", source, destination)
      end
    end

    defp copy_entries(source, destination, relative, source_root, destination_root) do
      case File.ls(source) do
        {:ok, names} ->
          Enum.reduce_while(names, :ok, fn name, :ok ->
            child_relative = Path.join(relative, name)

            result =
              if child_relative in @snapshot_ignored do
                :ok
              else
                copy_entry(
                  Path.join(source, name),
                  Path.join(destination, name),
                  child_relative,
                  source_root,
                  destination_root
                )
              end

            case result do
              :ok -> {:cont, :ok}
              {:error, _message} = error -> {:halt, error}
            end
          end)

        {:error, reason} ->
          snapshot_error(source, "list directory", reason)
      end
    end

    defp copy_entry(source, destination, relative, source_root, destination_root) do
      case File.lstat(source) do
        {:ok, %{type: :directory, mode: mode}} ->
          with :ok <-
                 file_operation(File.mkdir_p(destination), destination, "create directory"),
               :ok <- file_operation(File.chmod(destination, mode), destination, "set mode") do
            copy_entries(source, destination, relative, source_root, destination_root)
          end

        {:ok, %{type: :regular, mode: mode}} ->
          with :ok <-
                 file_operation(
                   File.mkdir_p(Path.dirname(destination)),
                   destination,
                   "create parent directory"
                 ),
               :ok <- file_operation(File.cp(source, destination), source, "copy file"),
               :ok <- file_operation(File.chmod(destination, mode), destination, "set mode") do
            :ok
          end

        {:ok, %{type: :symlink}} ->
          copy_symlink(source, destination, relative, source_root, destination_root)

        {:ok, %{type: type}} ->
          {:error,
           "cannot adopt existing client: unsupported #{type} entry #{Path.relative_to(source, source_root)}"}

        {:error, reason} ->
          snapshot_error(source, "inspect entry", reason)
      end
    end

    defp copy_symlink(source, destination, relative, source_root, destination_root) do
      case File.read_link(source) do
        {:ok, target} ->
          resolved = Path.expand(target, Path.dirname(source))

          with {:ok, relative_target} <- relative_inside(resolved, source_root) do
            snapshot_target = Path.join(destination_root, relative_target)
            copied_target = if Path.type(target) == :absolute, do: snapshot_target, else: target

            with :ok <-
                   file_operation(
                     File.mkdir_p(Path.dirname(destination)),
                     destination,
                     "create parent directory"
                   ) do
              file_operation(File.ln_s(copied_target, destination), destination, "create symlink")
            end
          else
            :error ->
              {:error,
               "cannot adopt existing client: symlink #{relative} points outside the application root"}
          end

        {:error, reason} ->
          snapshot_error(source, "read symlink", reason)
      end
    end

    defp relative_inside(path, root) do
      root_parts = root |> Path.expand() |> Path.split()
      path_parts = path |> Path.expand() |> Path.split()

      case Enum.split(path_parts, length(root_parts)) do
        {^root_parts, []} -> {:ok, "."}
        {^root_parts, relative_parts} -> {:ok, Path.join(relative_parts)}
        _outside -> :error
      end
    end

    defp file_operation(:ok, _path, _action), do: :ok

    defp file_operation({:error, reason}, path, action) do
      snapshot_error(path, action, reason)
    end

    defp snapshot_error(path, action, reason) do
      {:error,
       "cannot adopt existing client: could not #{action} #{path}: #{:file.format_error(reason)}"}
    end

    defp temporary_root do
      case System.tmp_dir() do
        nil ->
          {:error, "cannot adopt existing client: no temporary directory is available"}

        directory ->
          temporary_root(directory)
      end
    end

    defp temporary_root(directory) do
      name =
        "rekindle-adopt-" <> (:crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false))

      path = Path.join(directory, name)

      case File.mkdir(path) do
        :ok ->
          case File.chmod(path, 0o700) do
            :ok ->
              {:ok, path}

            {:error, reason} ->
              mode_error = snapshot_error(path, "set temporary snapshot mode", reason)

              case File.rmdir(path) do
                :ok ->
                  mode_error

                {:error, cleanup_reason} ->
                  snapshot_error(path, "remove temporary snapshot", cleanup_reason)
              end
          end

        {:error, :eexist} ->
          temporary_root(directory)

        {:error, reason} ->
          snapshot_error(path, "create temporary snapshot", reason)
      end
    end

    defp remove_snapshot(path) do
      case File.rm_rf(path) do
        {:ok, _removed} ->
          :ok

        {:error, reason, failed_path} ->
          snapshot_error(failed_path, "remove temporary snapshot", reason)
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
