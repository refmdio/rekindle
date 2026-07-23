if Code.ensure_loaded?(Igniter) do
  defmodule Rekindle.Install.Cargo do
    @moduledoc false

    alias Rekindle.Integration
    alias Rekindle.Toolchain.Process

    @platforms %{web: "wasm32-unknown-unknown"}

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

      if File.regular?(Path.join(client_root, "Cargo.toml")) do
        with_lock_preserved(client_root, callback)
      else
        project_root = temporary_root()

        try do
          :ok = materialize(igniter, project_root)
          callback.(Path.join(project_root, "client"), false)
        after
          File.rm_rf(project_root)
        end
      end
    end

    defp with_lock_preserved(client_root, callback) do
      with {:ok, workspace_root} <- workspace_root(client_root) do
        lock = Path.join(workspace_root, "Cargo.lock")

        case File.read(lock) do
          {:ok, _contents} ->
            callback.(client_root, true)

          {:error, :enoent} ->
            try do
              callback.(client_root, false)
            after
              File.rm(lock)
            end

          {:error, reason} ->
            {:error, "cannot inspect Cargo.lock: #{:file.format_error(reason)}"}
        end
      end
    end

    defp workspace_root(client_root) do
      arguments = [
        "locate-project",
        "--workspace",
        "--message-format",
        "plain",
        "--manifest-path",
        Path.join(client_root, "Cargo.toml")
      ]

      case Process.run(Rekindle.Toolchain.cargo_path(), arguments,
             cd: client_root,
             timeout: 30_000,
             output_limit: 16_000
           ) do
        {:ok, %{status: 0, output: output}} ->
          case output |> String.split("\n", trim: true) |> List.last() do
            nil -> {:error, "cargo locate-project returned no workspace manifest"}
            manifest -> {:ok, Path.dirname(manifest)}
          end

        {:ok, result} ->
          {:error, "cargo locate-project failed with status #{result.status}: #{result.output}"}

        {:error, reason} ->
          {:error, "cargo locate-project could not run: #{inspect(reason)}"}
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
