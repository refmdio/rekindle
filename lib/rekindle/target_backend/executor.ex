defmodule Rekindle.TargetBackend.Executor do
  @moduledoc false

  alias Rekindle.ArtifactStore
  alias Rekindle.ArtifactStore.{Descriptor, Member, Staging}
  alias Rekindle.BuildGraph.Identity
  alias Rekindle.Config.ProcessPolicy
  alias Rekindle.ProcessRunner
  alias Rekindle.ProcessRunner.Result
  alias Rekindle.SealedArtifact.{Compatibility, Desktop, Web}

  alias Rekindle.{
    AdmittedSeal,
    BackendContext,
    CanonicalValue,
    ExecutionResult,
    ExternalArtifact,
    ExternalPlan,
    Diagnostic,
    Failure,
    QualifiedPath,
    TargetBackend
  }

  @manifest_limit 67_108_864

  @spec execute(
          TargetBackend.admission(),
          Rekindle.target(),
          (QualifiedPath.t() -> BackendContext.t()),
          keyword()
        ) ::
          {:ok, AdmittedSeal.t(), ExecutionResult.t(), [Rekindle.Diagnostic.t()]}
          | {:error, Failure.t()}
  def execute(admission, target, context_builder, options)
      when target in [:web, :desktop] and is_function(context_builder, 1) and is_list(options) do
    with {:ok, services} <- services(options),
         :ok <- valid_admission(admission),
         {:ok, %Staging{} = staging} <- ArtifactStore.allocate(services.store, target) do
      execute_owned(admission, context_builder, staging, services)
    end
  rescue
    _exception -> contract_failure(target, "Extension execution failed")
  catch
    _kind, _reason -> contract_failure(target, "Extension execution failed")
  end

  def execute(_admission, target, _context_builder, _options),
    do: contract_failure(target, "Extension execution request is invalid")

  defp execute_owned(admission, context_builder, staging, services) do
    result =
      try do
        QualifiedPath.with_scope(fn ->
          context = context_builder.(QualifiedPath.issue(staging.path, :read_write))
          execute_staged(admission, context, staging, services)
        end)
      rescue
        _exception -> contract_failure(staging.target, "Extension execution failed")
      catch
        _kind, _reason -> contract_failure(staging.target, "Extension execution failed")
      end

    case result do
      {:ok, _admitted, _execution, _diagnostics} = success ->
        success

      {:error, %Failure{} = failure} ->
        case ArtifactStore.discard(staging) do
          :ok -> {:error, failure}
          {:error, %Failure{} = cleanup} -> {:error, cleanup}
        end

      _unexpected ->
        case ArtifactStore.discard(staging) do
          :ok -> contract_failure(staging.target, "Extension execution failed")
          {:error, %Failure{} = cleanup} -> {:error, cleanup}
        end
    end
  end

  defp execute_staged(admission, context, staging, services) do
    with :ok <- valid_context(context, admission, staging),
         {:ok, %ExternalPlan{} = plan} <-
           TargetBackend.invoke_plan(admission.module, context, admission.options),
         {:ok, command} <- command(plan, context, services),
         {:ok, %Result{execution: execution} = result} <- run(command, context, services),
         {:ok, process_diagnostics} <- process_diagnostics(plan, result, context),
         {:ok, %ExternalArtifact{} = artifact} <-
           TargetBackend.invoke_finalize(
             admission.module,
             context,
             admission.options,
             execution
           ),
         {:ok, manifest} <- manifest(artifact, plan, context, staging),
         {:ok, descriptor} <- descriptor(manifest, context),
         {:ok, generation} <- ArtifactStore.seal(staging, descriptor),
         {:ok, sealed} <- sealed(context.target, generation, context.source_revision, manifest),
         {:ok, admitted} <- AdmittedSeal.admit(services.store, sealed) do
      diagnostics =
        Enum.take(
          process_diagnostics ++ artifact.supplemental_diagnostics,
          diagnostic_limit(context)
        )

      {:ok, admitted, execution, diagnostics}
    end
  end

  defp services(options) do
    if Keyword.keyword?(options) and
         Keyword.keys(options) |> Enum.sort() == [:helper, :process, :runner, :store] do
      services = Map.new(options)

      if is_pid(services.runner) and is_pid(services.store) and
           is_binary(services.helper) and Path.type(services.helper) == :absolute and
           match?(%ProcessPolicy{}, services.process) do
        {:ok, services}
      else
        contract_failure(nil, "Extension execution services are invalid")
      end
    else
      contract_failure(nil, "Extension execution services are invalid")
    end
  end

  defp valid_admission(admission) when is_map(admission) do
    if Map.keys(admission) |> Enum.sort() ==
         [:backend_id, :backend_version, :module, :options, :options_digest] and
         is_atom(admission.module) and is_binary(admission.backend_id) and
         is_binary(admission.backend_version) and digest?(admission.options_digest) do
      :ok
    else
      contract_failure(nil, "Extension admission is invalid")
    end
  end

  defp valid_admission(_admission), do: contract_failure(nil, "Extension admission is invalid")

  defp valid_context(%BackendContext{} = context, admission, staging) do
    with true <- context.contract_version == 1,
         true <- context.target == staging.target,
         true <- context.backend_id == admission.backend_id,
         true <- context.backend_version == admission.backend_version,
         true <- context.options_digest == admission.options_digest,
         true <- is_integer(context.source_revision) and context.source_revision >= 0,
         true <- Compatibility.integration_identity?(context.integration_identity, context.target),
         {:ok, project_root} <- QualifiedPath.resolve(context.project_root, :read),
         {:ok, client_root} <- QualifiedPath.resolve(context.client_root, :read),
         {:ok, staging_root} <- QualifiedPath.resolve(context.staging_root, :read_write),
         true <- staging_root == staging.path,
         true <- roots_are_distinct?([project_root, client_root, staging_root]),
         :ok <- valid_host_requirements(context) do
      :ok
    else
      _ -> contract_failure(context.target, "Extension context is invalid")
    end
  end

  defp valid_context(_context, _admission, staging),
    do: contract_failure(staging.target, "Extension context is invalid")

  defp valid_host_requirements(context) do
    requirements = host_requirements(context)

    digest =
      :crypto.hash(
        :sha256,
        "rekindle-host-requirements-v1\0" <> CanonicalValue.encode!(requirements)
      )
      |> Base.encode16(case: :lower)

    if Compatibility.host_requirements?(requirements, context.target) and
         digest == context.host_requirements_digest,
       do: :ok,
       else: contract_failure(context.target, "Extension host requirements are invalid")
  end

  defp command(plan, context, services) do
    with {:ok, project} <- QualifiedPath.resolve(context.project_root, :read),
         {:ok, client} <- QualifiedPath.resolve(context.client_root, :read),
         {:ok, staging} <- QualifiedPath.resolve(context.staging_root, :read_write),
         roots = %{project: project, client: client, staging: staging},
         {:ok, executable} <- qualified_executable(plan.executable, Map.values(roots)),
         {:ok, cwd_root} <- Map.fetch(roots, plan.cwd.root),
         {:ok, cwd} <- qualified_cwd(cwd_root, plan.cwd.path),
         {:ok, executable_identity} <- executable_identity(executable, roots),
         {:ok, plan_identity} <- Identity.external_plan(plan, executable_identity),
         true <- plan.timeout_ms <= services.process.build_timeout_ms,
         true <- Enum.all?(plan.env_set, &(not String.starts_with?(&1.name, "REKINDLE_"))) do
      env_set =
        Enum.map(plan.env_set, &{&1.name, &1.value}) ++
          [
            {"REKINDLE_BUILD_KEY", plan_identity.digest},
            {"REKINDLE_EXPECTED_MANIFEST", plan.expected_manifest}
          ]

      env_set = Enum.sort_by(env_set, &elem(&1, 0))
      redact_values = for entry <- plan.env_set, entry.secret, do: entry.value
      process = services.process

      {:ok,
       [
         target: context.target,
         build_key: plan_identity.digest,
         helper: services.helper,
         executable: executable,
         argv: plan.argv,
         cwd: cwd,
         env_mode: :replace,
         env_set: env_set,
         env_unset: [],
         terminate_grace_ms: process.terminate_grace_ms,
         kill_grace_ms: process.kill_grace_ms,
         output_bytes_per_stream: process.output_bytes_per_stream,
         build_timeout_ms: plan.timeout_ms,
         cleanup_timeout_ms: process.kill_grace_ms,
         redact_values: redact_values
       ]}
    else
      _ -> contract_failure(context.target, "Extension plan path authority is invalid")
    end
  end

  defp run(command, context, services) do
    case ProcessRunner.run(services.runner, command) do
      {:ok, reference} ->
        receive do
          {:rekindle_process, ^reference, result} -> result
        after
          services.process.build_timeout_ms + services.process.kill_grace_ms + 1_000 ->
            _ = ProcessRunner.cancel(services.runner, reference, :caller)
            contract_failure(context.target, "Extension runner did not settle")
        end

      {:error, %Failure{} = failure} ->
        {:error, failure}
    end
  end

  defp manifest(artifact, plan, context, staging) do
    expected =
      if context.target == :web,
        do: "rekindle-web-manifest-v2.json",
        else: "rekindle-native-manifest-v2.json"

    with true <- artifact.manifest == plan.expected_manifest,
         true <- artifact.manifest == expected,
         path = Path.join(staging.path, artifact.manifest),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         true <- size <= @manifest_limit,
         {:ok, bytes} <- File.read(path),
         {:ok, value} when is_map(value) <- Jason.decode(bytes),
         true <- CanonicalValue.encode!(value) == bytes,
         :ok <- validate_manifest(context.target, value),
         true <- exact_context_echo?(value, context) do
      {:ok, value}
    else
      _ -> artifact_failure(context.target, "Extension manifest is invalid")
    end
  end

  defp process_diagnostics(%ExternalPlan{diagnostic_mode: :opaque}, result, context) do
    diagnostics =
      [{:stdout, result.stdout}, {:stderr, result.stderr}]
      |> Enum.flat_map(fn
        {_stream, ""} ->
          []

        {stream, bytes} ->
          case Diagnostic.new(
                 target: context.target,
                 stage: :execution,
                 severity: :info,
                 code: :backend_output,
                 message: "Extension #{stream}",
                 rendered: bounded(bytes, 16_384)
               ) do
            {:ok, diagnostic} -> [diagnostic]
            _ -> []
          end
      end)

    {:ok, diagnostics}
  end

  defp process_diagnostics(%ExternalPlan{diagnostic_mode: :cargo_json}, result, context) do
    result.stdout
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, diagnostics} ->
      if byte_size(line) > 1_048_576 do
        {:halt,
         {:error,
          Failure.new!(
            target: context.target,
            stage: :execution,
            code: :output_limit,
            message: "Extension diagnostic line exceeds 1 MiB"
          )}}
      else
        case cargo_diagnostic(line, context.target) do
          {:ok, nil} -> {:cont, {:ok, diagnostics}}
          {:ok, diagnostic} -> {:cont, {:ok, [diagnostic | diagnostics]}}
          {:error, %Failure{} = failure} -> {:halt, {:error, failure}}
        end
      end
    end)
    |> case do
      {:ok, diagnostics} -> {:ok, Enum.reverse(diagnostics)}
      {:error, %Failure{}} = error -> error
    end
  end

  defp cargo_diagnostic(line, target) do
    case Jason.decode(line) do
      {:ok, %{"reason" => "compiler-message", "message" => body}}
      when is_map(body) ->
        with level when is_binary(level) <- body["level"],
             message when is_binary(message) <- body["message"],
             {:ok, diagnostic} <-
               Diagnostic.new(
                 target: target,
                 stage: :execution,
                 severity: diagnostic_severity(level),
                 code: :backend_compiler,
                 message: bounded(message, 4_096),
                 rendered: bounded_optional(body["rendered"], 16_384)
               ) do
          {:ok, diagnostic}
        else
          _ -> diagnostic_failure(target)
        end

      {:ok, _other} ->
        {:ok, nil}

      {:error, _reason} ->
        diagnostic_failure(target)
    end
  end

  defp diagnostic_failure(target) do
    {:error,
     Failure.new!(
       target: target,
       stage: :execution,
       code: :cargo_protocol,
       message: "Extension Cargo diagnostic output is invalid"
     )}
  end

  defp diagnostic_severity("error"), do: :error
  defp diagnostic_severity("warning"), do: :warning
  defp diagnostic_severity(_level), do: :info

  defp bounded_optional(nil, _limit), do: nil
  defp bounded_optional(value, limit) when is_binary(value), do: bounded(value, limit)
  defp bounded_optional(_value, _limit), do: nil

  defp bounded(value, limit) when is_binary(value) do
    if byte_size(value) <= limit,
      do: value,
      else: binary_part(value, 0, limit)
  end

  defp diagnostic_limit(context) do
    case context.limits do
      %{"diagnostic_limit" => value} when is_integer(value) and value in 1..4_096 -> value
      %{diagnostic_limit: value} when is_integer(value) and value in 1..4_096 -> value
      _ -> 512
    end
  end

  defp validate_manifest(:web, value), do: Web.validate_manifest(value)
  defp validate_manifest(:desktop, value), do: Desktop.validate_manifest(value)

  defp exact_context_echo?(manifest, context) do
    producer = %{
      "kind" => "extension",
      "backend_id" => context.backend_id,
      "backend_version" => context.backend_version,
      "options_digest" => context.options_digest
    }

    build = manifest["build"]

    manifest["rekindle_version"] == context.rekindle_version and
      manifest["application_id"] == context.application_id and
      manifest["target"] == Atom.to_string(context.target) and manifest["producer"] == producer and
      manifest["host_requirements"] == host_requirements(context) and
      build["package"] == context.package and build["binary"] == context.binary and
      build["profile"] == context.profile and build["features"] == context.features and
      target_echo?(manifest, context)
  rescue
    _ -> false
  end

  defp target_echo?(manifest, %{target: :web} = context),
    do: manifest["hot_styles"] == context.hot_styles

  defp target_echo?(manifest, %{target: :desktop} = context),
    do: manifest["runtime"] == context.runtime_manifest

  defp descriptor(manifest, context) do
    members =
      case context.target do
        :web ->
          Enum.map(manifest["members"], fn member ->
            %Member{
              path: "members/" <> member["path"],
              sha256: member["sha256"],
              size: member["size"],
              mode: :regular
            }
          end)

        :desktop ->
          executable = manifest["executable"]

          [
            %Member{
              path: executable["path"],
              sha256: executable["sha256"],
              size: executable["size"],
              mode: :executable_owner
            }
          ]
      end

    {:ok,
     %Descriptor{
       artifact_id: manifest["artifact_id"],
       manifest_path:
         if(context.target == :web,
           do: "rekindle-web-manifest-v2.json",
           else: "rekindle-native-manifest-v2.json"
         ),
       manifest_digest: manifest["manifest_digest"],
       support_level: :not_applicable,
       profile: context.profile,
       source_revision: context.source_revision,
       members: members
     }}
  end

  defp sealed(:web, generation, revision, manifest),
    do:
      Web.new(
        generation: generation,
        source_revision: revision,
        manifest: manifest,
        seal_result: :sealed
      )

  defp sealed(:desktop, generation, revision, manifest),
    do:
      Desktop.new(
        generation: generation,
        source_revision: revision,
        manifest: manifest,
        seal_result: :sealed
      )

  defp qualified_executable(path, roots) do
    with true <- Path.type(path) == :absolute and Path.expand(path) == path,
         root when is_binary(root) <- Enum.find(roots, &inside?(path, &1)),
         true <- no_symlinks?(path, root),
         {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o111) != 0 do
      {:ok, path}
    else
      _ -> :error
    end
  end

  defp qualified_cwd(root, "."), do: qualified_directory(root, root)

  defp qualified_cwd(root, relative) do
    path = Path.expand(relative, root)
    if inside?(path, root), do: qualified_directory(path, root), else: :error
  end

  defp qualified_directory(path, root) do
    with true <- no_symlinks?(path, root),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(path) do
      {:ok, path}
    else
      _ -> :error
    end
  end

  defp executable_identity(path, roots) do
    root = Enum.find_value(roots, fn {name, root} -> if inside?(path, root), do: {name, root} end)

    with {name, root} <- root,
         {:ok, %File.Stat{size: size}} <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, path_identity} <-
           Identity.digest("rekindle-external-path-v1\0", %{
             "root" => Atom.to_string(name),
             "path" => Path.relative_to(path, root)
           }) do
      {:ok,
       %{
         path_digest: path_identity.digest,
         content_sha256: sha256(bytes),
         size: size
       }}
    else
      _ -> :error
    end
  end

  defp roots_are_distinct?(roots), do: Enum.uniq(roots) == roots

  defp inside?(path, root),
    do: path == root or String.starts_with?(path, root <> "/")

  defp no_symlinks?(path, root) do
    relative = Path.relative_to(path, root)

    relative
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, current ->
      next = Path.join(current, segment)

      case File.lstat(next) do
        {:ok, %File.Stat{type: type}} when type in [:regular, :directory] -> {:cont, next}
        _ -> {:halt, false}
      end
    end)
    |> is_binary()
  end

  defp host_requirements(context) do
    %{
      "v" => 1,
      "target" => Atom.to_string(context.target),
      "integration_identity" => context.integration_identity,
      "host_descriptor" => context.host_descriptor,
      "graphics_requirement" => context.graphics_requirement
    }
  end

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp artifact_failure(target, message) do
    {:error,
     Failure.new!(target: target, stage: :artifact, code: :manifest_invalid, message: message)}
  end

  defp contract_failure(target, message) do
    {:error,
     Failure.new!(
       target: if(target in [:web, :desktop], do: target, else: nil),
       stage: :internal,
       code: :contract_violation,
       message: message
     )}
  end
end
