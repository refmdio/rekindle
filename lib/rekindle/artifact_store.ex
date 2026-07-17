defmodule Rekindle.ArtifactStore do
  @moduledoc false

  use GenServer

  import Bitwise

  alias Rekindle.ArtifactStore.{Descriptor, Filesystem, Lease, Member, Staging}
  alias Rekindle.SealedArtifact.{Identity, Validation}
  alias Rekindle.{CanonicalValue, Failure, GenerationRef}

  @manifest_limit 67_108_864
  @member_limit 100_000
  @safe_integer 9_007_199_254_740_991
  @activation_write_checkpoints %{
    journal: %{
      created: :activation_journal_created,
      written: :activation_journal_written,
      file_synced: :activation_journal_file_synced,
      renamed: :activation_journal_renamed,
      directory_synced: :activation_journal_directory_synced
    },
    fallback: %{
      created: :activation_fallback_created,
      written: :activation_fallback_written,
      file_synced: :activation_fallback_file_synced,
      renamed: :activation_fallback_renamed,
      directory_synced: :activation_fallback_directory_synced
    },
    current: %{
      created: :activation_current_created,
      written: :activation_current_written,
      file_synced: :activation_current_file_synced,
      renamed: :activation_current_renamed,
      directory_synced: :activation_current_directory_synced
    }
  }

  defstruct [
    :root,
    :session_id,
    :retained_generations,
    :max_generation_bytes,
    quarantined?: false,
    attempts: %{},
    attempt_monitors: %{},
    leases: %{},
    lease_monitors: %{}
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    name = Keyword.get(options, :name)
    options = Keyword.delete(options, :name)
    GenServer.start_link(__MODULE__, options, if(name, do: [name: name], else: []))
  end

  @spec allocate(GenServer.server(), Rekindle.target()) ::
          {:ok, Staging.t()} | {:error, Failure.t()}
  def allocate(server, target), do: GenServer.call(server, {:allocate, target}, 30_000)

  @spec seal(Staging.t(), Descriptor.t(), keyword()) ::
          {:ok, GenerationRef.t()} | {:error, Failure.t()}
  def seal(%Staging{store: store} = staging, %Descriptor{} = descriptor, options \\ []),
    do: GenServer.call(store, {:seal, staging, descriptor, options}, :infinity)

  @spec activate(GenServer.server(), GenerationRef.t(), non_neg_integer()) ::
          :ok | {:error, Failure.t()}
  @spec activate(GenServer.server(), GenerationRef.t(), non_neg_integer(), keyword()) ::
          :ok | {:error, Failure.t()}
  def activate(server, generation, source_revision, options \\ []),
    do: GenServer.call(server, {:activate, generation, source_revision, options}, :infinity)

  @spec current(GenServer.server(), Rekindle.target()) ::
          {:ok, GenerationRef.t()} | :none | {:error, Failure.t()}
  def current(server, target), do: GenServer.call(server, {:current, target}, :infinity)

  @spec fallback(GenServer.server(), Rekindle.target()) ::
          {:ok, GenerationRef.t()} | :none | {:error, Failure.t()}
  def fallback(server, target), do: GenServer.call(server, {:fallback, target}, :infinity)

  @spec acquire(GenServer.server(), GenerationRef.t()) ::
          {:ok, Lease.t()} | {:error, Failure.t()}
  def acquire(server, generation),
    do: GenServer.call(server, {:acquire, generation, :any}, :infinity)

  @spec acquire(GenServer.server(), GenerationRef.t(), non_neg_integer()) ::
          {:ok, Lease.t()} | {:error, Failure.t()}
  def acquire(server, generation, source_revision),
    do: GenServer.call(server, {:acquire, generation, source_revision}, :infinity)

  @type release_authority ::
          {:rekindle_artifact_release, GenServer.server(), reference(), reference()}

  @spec authorize_release(Lease.t()) ::
          {:ok, release_authority()} | {:error, Failure.t()}
  def authorize_release(%Lease{store: store} = lease),
    do: GenServer.call(store, {:authorize_release, lease})

  @spec release(Lease.t() | release_authority()) :: :ok | {:error, Failure.t()}
  def release(%Lease{store: store} = lease), do: GenServer.call(store, {:release, lease})

  def release({:rekindle_artifact_release, store, token, authority})
      when is_pid(store) and is_reference(token) and is_reference(authority),
      do: GenServer.call(store, {:release_authority, token, authority})

  @spec revoke_release_authority(release_authority()) :: :ok | {:error, Failure.t()}
  def revoke_release_authority({:rekindle_artifact_release, store, token, authority})
      when is_pid(store) and is_reference(token) and is_reference(authority),
      do: GenServer.call(store, {:revoke_release_authority, token, authority})

  @spec valid_lease?(Lease.t()) :: boolean()
  def valid_lease?(%Lease{store: store} = lease),
    do: GenServer.call(store, {:valid_lease, lease}, :infinity)

  @spec sealed_descriptor(Lease.t()) :: {:ok, Descriptor.t()} | {:error, Failure.t()}
  def sealed_descriptor(%Lease{store: store} = lease),
    do: GenServer.call(store, {:sealed_descriptor, lease}, :infinity)

  @spec collect(GenServer.server(), [GenerationRef.t()], keyword()) ::
          {:ok, map()} | {:error, Failure.t()}
  def collect(server, protected \\ [], options \\ []),
    do: GenServer.call(server, {:collect, protected, options}, :infinity)

  @impl true
  def init(options) do
    root = Keyword.get(options, :root)
    retained = Keyword.get(options, :retained_generations, 3)
    max_bytes = Keyword.get(options, :max_generation_bytes, 2_147_483_648)

    with true <-
           Keyword.keys(options) -- [:root, :retained_generations, :max_generation_bytes] == [],
         true <- safe_root?(root),
         true <- is_integer(retained) and retained in 1..20,
         true <- is_integer(max_bytes) and max_bytes in 67_108_864..17_179_869_184,
         {:ok, layout_quarantine?} <- initialize_layout(root),
         {:ok, temporary_quarantine?} <-
           if(layout_quarantine?,
             do: {:ok, true},
             else: recover_temporaries_before_identity(root)
           ),
         {:ok, identity_quarantine?} <- ensure_project_identity(root, temporary_quarantine?),
         quarantined_before_recovery? = temporary_quarantine? or identity_quarantine?,
         {:ok, quarantined?} <-
           if(quarantined_before_recovery?, do: {:ok, true}, else: recover(root)) do
      {:ok,
       %__MODULE__{
         root: root,
         session_id: Filesystem.random_id(),
         retained_generations: retained,
         max_generation_bytes: max_bytes,
         quarantined?: quarantined?
       }}
    else
      {:error, %Failure{} = failure} -> {:stop, failure}
      _ -> {:stop, invalid(:configuration, :config_invalid, "Artifact store options are invalid")}
    end
  end

  @impl true
  def handle_call({:allocate, target}, {owner, _tag}, state) do
    with :ok <- writable(state),
         true <- target in [:web, :desktop],
         {:ok, staging} <- allocate_staging(state, owner, target) do
      monitor = Process.monitor(owner)
      attempt = %{owner: owner, monitor: monitor, staging: staging}

      state = %{
        state
        | attempts: Map.put(state.attempts, staging.attempt_id, attempt),
          attempt_monitors: Map.put(state.attempt_monitors, monitor, staging.attempt_id)
      }

      {:reply, {:ok, staging}, state}
    else
      false ->
        {:reply, {:error, invalid(:configuration, :config_invalid, "Target is invalid")}, state}

      {:error, %Failure{} = failure} ->
        {:reply, {:error, failure}, state}

      {:quarantine, %Failure{} = failure} ->
        {:reply, {:error, failure}, %{state | quarantined?: true}}
    end
  end

  def handle_call({:seal, staging, descriptor, options}, {owner, _tag}, state) do
    result =
      with :ok <- writable(state),
           :ok <- validate_seal_call(state, staging, descriptor, options, owner),
           {:ok, generation} <- publish(state, staging, descriptor, options) do
        {:ok, generation}
      end

    case result do
      {:ok, generation} ->
        {:reply, {:ok, generation}, drop_attempt(state, staging.attempt_id, false)}

      {:error, %Failure{} = failure} ->
        cleanup = cleanup_attempt(state, staging.attempt_id)
        state = drop_attempt(state, staging.attempt_id, false)
        failure = if cleanup == :ok, do: failure, else: elem(cleanup, 1)
        {:reply, {:error, failure}, state}

      {:quarantine, %Failure{} = failure} ->
        {:reply, {:error, failure}, %{state | quarantined?: true}}
    end
  end

  def handle_call({:activate, generation, revision, options}, _from, state) do
    result =
      with :ok <- writable(state),
           true <- valid_activation_options?(options),
           true <- uint?(revision),
           {:ok, generation} <- validate_generation(state, generation),
           :ok <- recover_activation(state.root, generation.target),
           :ok <- generation_source_revision(state, generation, revision),
           {:ok, current} <- pointer_value(state, :current, generation.target),
           {:ok, fallback} <- pointer_value(state, :fallback, generation.target) do
        activate_generation(state, generation, revision, current, fallback, options)
      else
        false ->
          {:error, invalid(:configuration, :config_invalid, "Activation request is invalid")}

        {:error, %Failure{} = failure} ->
          {:error, failure}

        {:quarantine, %Failure{} = failure} ->
          {:quarantine, failure}
      end

    case result do
      :ok ->
        {:reply, :ok, state}

      {:error, %Failure{} = failure} ->
        {:reply, {:error, failure}, state}

      {:quarantine, %Failure{} = failure} ->
        {:reply, {:error, failure}, %{state | quarantined?: true}}
    end
  end

  def handle_call({:current, target}, _from, state) do
    pointer_reply(state, :current, target)
  end

  def handle_call({:fallback, target}, _from, state) do
    pointer_reply(state, :fallback, target)
  end

  def handle_call({:acquire, generation, source_revision}, {owner, _tag}, state) do
    with :ok <- usable(state),
         true <- source_revision == :any or uint?(source_revision),
         {:ok, generation} <- validate_generation(state, generation),
         :ok <- maybe_generation_source_revision(state, generation, source_revision) do
      token = make_ref()
      monitor = Process.monitor(owner)

      lease = %Lease{
        store: self(),
        token: token,
        target: generation.target,
        generation_id: generation.generation_id,
        artifact_id: generation.artifact_id
      }

      entry = %{lease: lease, owner: owner, monitor: monitor, release_authorities: MapSet.new()}

      state = %{
        state
        | leases: Map.put(state.leases, token, entry),
          lease_monitors: Map.put(state.lease_monitors, monitor, token)
      }

      {:reply, {:ok, lease}, state}
    else
      false ->
        {:reply, {:error, invalid(:configuration, :config_invalid, "Revision is invalid")}, state}

      {:error, %Failure{} = failure} ->
        {:reply, {:error, failure}, state}
    end
  end

  def handle_call({:authorize_release, %Lease{token: token} = lease}, {owner, _tag}, state) do
    with :ok <- usable(state) do
      case Map.get(state.leases, token) do
        %{owner: ^owner, lease: ^lease} = entry ->
          authority = make_ref()
          release = {:rekindle_artifact_release, self(), token, authority}
          entry = %{entry | release_authorities: MapSet.put(entry.release_authorities, authority)}
          {:reply, {:ok, release}, put_in(state.leases[token], entry)}

        _ ->
          {:reply, {:error, lease_access_denied()}, state}
      end
    else
      {:error, %Failure{} = failure} -> {:reply, {:error, failure}, state}
    end
  end

  def handle_call({:release, %Lease{token: token} = lease}, {owner, _tag}, state) do
    case Map.get(state.leases, token) do
      %{owner: ^owner, lease: ^lease} -> {:reply, :ok, drop_lease(state, token)}
      _ -> {:reply, {:error, lease_access_denied()}, state}
    end
  end

  def handle_call({:release_authority, token, authority}, _from, state) do
    case Map.get(state.leases, token) do
      %{release_authorities: authorities} ->
        if MapSet.member?(authorities, authority) do
          {:reply, :ok, drop_lease(state, token)}
        else
          {:reply, {:error, lease_access_denied()}, state}
        end

      _ ->
        {:reply, {:error, lease_access_denied()}, state}
    end
  end

  def handle_call({:revoke_release_authority, token, authority}, _from, state) do
    case Map.get(state.leases, token) do
      %{release_authorities: authorities} = entry ->
        if MapSet.member?(authorities, authority) do
          entry = %{entry | release_authorities: MapSet.delete(authorities, authority)}
          {:reply, :ok, put_in(state.leases[token], entry)}
        else
          {:reply, {:error, lease_access_denied()}, state}
        end

      _ ->
        {:reply, {:error, lease_access_denied()}, state}
    end
  end

  def handle_call({:valid_lease, %Lease{} = lease}, {owner, _tag}, state) do
    valid? =
      not state.quarantined? and
        match?(
          %{owner: ^owner, lease: ^lease},
          Map.get(state.leases, lease.token)
        )

    {:reply, valid?, state}
  end

  def handle_call({:sealed_descriptor, %Lease{token: token} = lease}, {owner, _tag}, state) do
    result =
      with :ok <- usable(state) do
        case Map.get(state.leases, token) do
          %{owner: ^owner, lease: ^lease} ->
            with {:ok, descriptor} <- load_descriptor(state, lease.target, lease.artifact_id),
                 :ok <-
                   validate_tree(
                     artifact_path(state, lease.target, lease.artifact_id),
                     lease.target,
                     descriptor,
                     true
                   ) do
              {:ok, descriptor}
            end

          _ ->
            {:error, lease_access_denied()}
        end
      end

    {:reply, result, state}
  end

  def handle_call({:collect, protected, options}, _from, state) do
    with :ok <- writable(state),
         true <- Keyword.keyword?(options) and Keyword.keys(options) -- [:checkpoint] == [],
         {:ok, protected} <- protected_generations(protected),
         {:ok, result} <- collect_unreferenced(state, protected, options) do
      {:reply, {:ok, result}, state}
    else
      false ->
        {:reply,
         {:error, invalid(:configuration, :config_invalid, "Collection options are invalid")},
         state}

      {:error, %Failure{} = failure} ->
        {:reply, {:error, failure}, state}

      {:quarantine, %Failure{} = failure} ->
        {:reply, {:error, failure}, %{state | quarantined?: true}}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    cond do
      attempt_id = Map.get(state.attempt_monitors, monitor) ->
        _ = cleanup_attempt(state, attempt_id)
        {:noreply, drop_attempt(state, attempt_id, true)}

      token = Map.get(state.lease_monitors, monitor) ->
        {:noreply, drop_lease(state, token, true)}

      true ->
        {:noreply, state}
    end
  end

  defp initialize_layout(root) do
    with :ok <- Filesystem.ensure_private_directory(root) do
      if quarantine_control_present?(root) do
        {:ok, true}
      else
        case ensure_directories(root) do
          :ok -> {:ok, false}
          {:error, _} = error -> error
        end
      end
    end
  end

  defp ensure_project_id(root) do
    path = Path.join(root, "project-id")

    case File.lstat(path) do
      {:error, :enoent} ->
        with :ok <- validate_first_start_layout(root, []),
             :ok <- Filesystem.atomic_write(path, Filesystem.random_id(), :project_id) do
          :ok
        else
          _ ->
            {:error,
             invalid(:configuration, :path_invalid, "Project identity is missing from state")}
        end

      {:ok, _stat} ->
        with :ok <- qualify_private_file(path),
             {:ok, value} <- File.read(path),
             true <- id?(value) do
          :ok
        else
          {:error, %Failure{} = failure} ->
            {:error, failure}

          {:error, _reason} ->
            {:error, invalid(:execution, :io_failed, "Project identity could not be read")}

          _ ->
            {:error, invalid(:configuration, :path_invalid, "Project identity is invalid")}
        end

      {:error, _reason} ->
        {:error, invalid(:execution, :io_failed, "Project identity could not be read")}
    end
  end

  defp ensure_project_identity(_root, true), do: {:ok, true}

  defp ensure_project_identity(root, false) do
    case ensure_project_id(root) do
      :ok -> {:ok, false}
      {:error, %Failure{} = failure} -> quarantine(root, failure.message)
    end
  end

  defp ensure_directories(root) do
    directories =
      ["staging", "current", "fallback", "activations", "seals", "deletions"] ++
        for(
          parent <- ["generations", "references", "seals"],
          target <- ["web", "desktop"],
          do: Path.join(parent, target)
        )

    Enum.reduce_while(directories, :ok, fn relative, :ok ->
      case ensure_nested_directory(root, relative) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_nested_directory(root, relative) do
    relative
    |> Path.split()
    |> Enum.reduce_while({:ok, root}, fn segment, {:ok, parent} ->
      path = Path.join(parent, segment)

      case Filesystem.ensure_private_directory(path) do
        :ok -> {:cont, {:ok, path}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      {:error, _} = error -> error
    end
  end

  defp allocate_staging(state, owner, target) do
    Enum.reduce_while(1..32, nil, fn _attempt, _acc ->
      attempt_id = Filesystem.random_id()
      generation_id = unique_generation_id(state, target)
      attempt_path = Path.join([state.root, "staging", attempt_id])
      body = Path.join(attempt_path, "body")

      case File.mkdir(attempt_path) do
        :ok ->
          marker = %{
            "v" => 1,
            "attempt_id" => attempt_id,
            "generation_id" => generation_id,
            "session_id" => state.session_id,
            "target" => Atom.to_string(target),
            "owner" => inspect(owner)
          }

          result =
            with :ok <- File.chmod(attempt_path, 0o700),
                 :ok <- File.mkdir(body),
                 :ok <- File.chmod(body, 0o700),
                 :ok <-
                   Filesystem.atomic_write(
                     Path.join(attempt_path, "attempt-v1.json"),
                     marker,
                     :attempt_marker
                   ),
                 :ok <- Filesystem.sync_directory(Path.join(state.root, "staging")) do
              {:ok,
               %Staging{
                 store: self(),
                 attempt_id: attempt_id,
                 generation_id: generation_id,
                 target: target,
                 path: body
               }}
            else
              {:error, _} = error -> error
            end

          case result do
            {:ok, _} = success ->
              {:halt, success}

            {:error, _} = error ->
              File.rm_rf(attempt_path)
              {:halt, error}
          end

        {:error, :eexist} ->
          {:cont, nil}

        {:error, _reason} ->
          {:halt, {:error, invalid(:execution, :io_failed, "Staging could not be allocated")}}
      end
    end)
    |> case do
      nil -> {:error, invalid(:internal, :unexpected_state, "Staging identity allocation failed")}
      result -> result
    end
  end

  defp validate_seal_call(state, staging, descriptor, options, owner) do
    allowed_options = [:checkpoint]

    with %{owner: ^owner, staging: ^staging} <- Map.get(state.attempts, staging.attempt_id),
         true <- staging.store == self(),
         true <- Keyword.keyword?(options),
         true <- Keyword.keys(options) -- allowed_options == [],
         :ok <- validate_descriptor(staging.target, descriptor),
         true <- descriptor_total_bytes(staging.path, descriptor) <= state.max_generation_bytes do
      :ok
    else
      {:error, %Failure{} = failure} -> {:error, failure}
      _ -> {:error, invalid(:internal, :contract_violation, "Seal request is invalid")}
    end
  end

  defp publish(state, staging, descriptor, options) do
    attempt_path = Path.dirname(staging.path)
    journal_path = Path.join(attempt_path, "seal-v1.json")
    final_path = artifact_path(state, staging.target, descriptor.artifact_id)

    with :ok <- validate_tree(staging.path, staging.target, descriptor, false),
         :ok <- checkpoint(options, :validated),
         :ok <-
           Filesystem.atomic_write(journal_path, seal_record(staging, descriptor), :seal_journal,
             checkpoint: Keyword.get(options, :checkpoint)
           ),
         :ok <- checkpoint(options, :journaled),
         :ok <- seal_tree(staging.path, descriptor),
         :ok <- checkpoint(options, :sealed),
         :ok <- publish_artifact(staging.path, final_path, staging.target, descriptor, options),
         :ok <- checkpoint(options, :renamed),
         :ok <- write_seal_metadata(state, staging.target, descriptor, options),
         :ok <- checkpoint(options, :metadata_published),
         {:ok, generation} <- write_reference(state, staging, descriptor, options),
         :ok <- checkpoint(options, :reference_published),
         :ok <- Filesystem.remove_tree(attempt_path),
         :ok <- Filesystem.sync_directory(Path.join(state.root, "staging")) do
      {:ok, generation}
    end
  end

  defp validate_descriptor(target, %Descriptor{} = descriptor) do
    members = descriptor.members

    with true <- digest?(descriptor.artifact_id),
         true <- digest?(descriptor.manifest_digest),
         true <- safe_profile?(descriptor.profile),
         true <- uint?(descriptor.source_revision),
         true <- safe_path?(descriptor.manifest_path),
         true <- is_list(members) and length(members) in 1..@member_limit,
         true <- Enum.all?(members, &valid_member?/1),
         paths <- Enum.map(members, & &1.path),
         true <- descriptor.manifest_path not in paths,
         true <- unique_paths?([descriptor.manifest_path | paths]),
         true <- target_manifest?(target, descriptor.manifest_path) do
      :ok
    else
      _ -> {:error, invalid(:artifact, :manifest_invalid, "Artifact descriptor is invalid")}
    end
  end

  defp validate_tree(root, target, descriptor, sealed?) do
    with {:ok, root_stat} <- lstat_directory(root),
         {:ok, files, directories} <- walk(root, root, root_stat),
         :ok <- exact_layout(files, directories, descriptor),
         :ok <- validate_directory_modes(root, directories, sealed?),
         :ok <- validate_members(root, descriptor.members, sealed?),
         :ok <- validate_manifest(root, target, descriptor, sealed?) do
      :ok
    end
  end

  defp walk(root, path, root_stat) do
    case File.ls(path) do
      {:ok, children} ->
        Enum.sort(children)
        |> Enum.reduce_while({:ok, [], []}, fn child, {:ok, files, directories} ->
          child_path = Path.join(path, child)

          case File.lstat(child_path) do
            {:ok, %File.Stat{type: :regular} = stat} ->
              if same_authority?(root_stat, stat) and stat.links == 1 do
                relative = Path.relative_to(child_path, root)
                {:cont, {:ok, [relative | files], directories}}
              else
                {:halt,
                 {:error,
                  invalid(:artifact, :artifact_changed, "Artifact member authority changed")}}
              end

            {:ok, %File.Stat{type: :directory} = stat} ->
              if same_authority?(root_stat, stat) do
                case walk(root, child_path, root_stat) do
                  {:ok, nested_files, nested_dirs} ->
                    relative = Path.relative_to(child_path, root)
                    {:cont, {:ok, nested_files ++ files, [relative | nested_dirs] ++ directories}}

                  {:error, _} = error ->
                    {:halt, error}
                end
              else
                {:halt,
                 {:error,
                  invalid(:artifact, :artifact_changed, "Artifact directory authority changed")}}
              end

            {:ok, _stat} ->
              {:halt,
               {:error, invalid(:artifact, :manifest_invalid, "Artifact contains a special file")}}

            {:error, _reason} ->
              {:halt,
               {:error,
                invalid(:artifact, :artifact_changed, "Artifact member could not be inspected")}}
          end
        end)
        |> case do
          {:ok, files, directories} -> {:ok, Enum.sort(files), Enum.sort(directories)}
          {:error, _} = error -> error
        end

      {:error, _reason} ->
        {:error, invalid(:execution, :io_failed, "Artifact directory could not be listed")}
    end
  end

  defp exact_layout(files, directories, descriptor) do
    expected_files =
      Enum.sort([descriptor.manifest_path | Enum.map(descriptor.members, & &1.path)])

    expected_directories =
      expected_files
      |> Enum.flat_map(&ancestors/1)
      |> Enum.uniq()
      |> Enum.sort()

    if files == expected_files and directories == expected_directories,
      do: :ok,
      else: {:error, invalid(:artifact, :manifest_invalid, "Artifact closure is incomplete")}
  end

  defp validate_members(root, members, sealed?) do
    Enum.reduce_while(members, :ok, fn member, :ok ->
      path = Path.join(root, member.path)

      with {:ok, %File.Stat{type: :regular} = stat} <- File.lstat(path),
           true <- stat.size == member.size,
           true <- member_mode?(stat.mode, member.mode, sealed?),
           {:ok, digest} <- Filesystem.sha256(path),
           true <- digest == member.sha256 do
        {:cont, :ok}
      else
        _ ->
          {:halt,
           {:error,
            invalid(:artifact, :artifact_changed, "Artifact member does not match its descriptor")}}
      end
    end)
  end

  defp validate_manifest(root, target, descriptor, sealed?) do
    path = Path.join(root, descriptor.manifest_path)

    with {:ok, %File.Stat{type: :regular, size: size, mode: mode}} <- File.lstat(path),
         true <- size <= @manifest_limit,
         true <- not sealed? or sealed_regular?(mode),
         {:ok, bytes} <- File.read(path),
         {:ok, value} <- Jason.decode(bytes),
         true <- CanonicalValue.encode!(value) == bytes,
         true <- Map.keys(value) |> Enum.all?(&is_binary/1),
         true <- value["contract_version"] == 1,
         true <- value["target"] == Atom.to_string(target),
         {:ok, artifact_id} <- Identity.derive(target, value),
         true <- artifact_id == value["artifact_id"],
         true <- value["artifact_id"] == descriptor.artifact_id,
         true <- value["manifest_digest"] == descriptor.manifest_digest,
         true <- manifest_digest(target, value) == descriptor.manifest_digest do
      :ok
    else
      _ ->
        {:error,
         invalid(:artifact, :manifest_invalid, "Artifact manifest does not match its descriptor")}
    end
  rescue
    _exception -> {:error, invalid(:artifact, :manifest_invalid, "Artifact manifest is invalid")}
  end

  defp seal_tree(root, descriptor) do
    files = [descriptor.manifest_path | Enum.map(descriptor.members, & &1.path)]

    with :ok <-
           Enum.reduce_while(files, :ok, fn relative, :ok ->
             path = Path.join(root, relative)
             mode = if executable_member?(descriptor, relative), do: 0o500, else: 0o400

             with :ok <- File.chmod(path, mode), :ok <- Filesystem.sync_file(path) do
               {:cont, :ok}
             else
               {:error, _} = error -> {:halt, normalize_io(error)}
             end
           end),
         :ok <- seal_directories(root, files) do
      :ok
    end
  end

  defp seal_directories(root, files) do
    directories =
      files
      |> Enum.flat_map(&ancestors/1)
      |> Enum.uniq()
      |> Enum.sort_by(&length(Path.split(&1)), :desc)
      |> Enum.map(&Path.join(root, &1))

    with :ok <-
           Enum.reduce_while(directories, :ok, fn directory, :ok ->
             with :ok <- File.chmod(directory, 0o500),
                  :ok <- Filesystem.sync_directory(directory) do
               {:cont, :ok}
             else
               {:error, _} = error -> {:halt, normalize_io(error)}
             end
           end),
         :ok <- Filesystem.sync_directory(root) do
      :ok
    end
  end

  defp validate_directory_modes(_root, _directories, false), do: :ok

  defp validate_directory_modes(root, directories, true) do
    ["." | directories]
    |> Enum.reduce_while(:ok, fn relative, :ok ->
      directory = if relative == ".", do: root, else: Path.join(root, relative)

      case File.lstat(directory) do
        {:ok, %File.Stat{type: :directory, mode: mode}} when (mode &&& 0o777) == 0o500 ->
          {:cont, :ok}

        _ ->
          {:halt,
           {:error, invalid(:artifact, :artifact_changed, "Sealed directory mode changed")}}
      end
    end)
  end

  defp publish_artifact(staging_path, final_path, target, descriptor, options) do
    case File.lstat(final_path) do
      {:error, :enoent} ->
        publish_new_artifact(staging_path, final_path, options)

      {:ok, %File.Stat{type: :directory}} ->
        reuse_artifact(staging_path, final_path, target, descriptor)

      {:ok, _stat} ->
        {:error, invalid(:artifact, :artifact_changed, "Artifact path is not a sealed directory")}

      {:error, _reason} ->
        {:error, invalid(:execution, :io_failed, "Artifact path could not be inspected")}
    end
  end

  defp publish_new_artifact(staging_path, final_path, options) do
    parent = Path.dirname(final_path)
    attempt_id = staging_path |> Path.dirname() |> Path.basename()
    hidden = Path.join(parent, ".#{Path.basename(final_path)}.#{attempt_id}.publishing")

    with :ok <- File.rename(staging_path, hidden),
         :ok <- Filesystem.sync_directory(parent),
         :ok <- checkpoint(options, :publication_staged),
         :ok <- File.chmod(hidden, 0o500),
         :ok <- Filesystem.sync_directory(hidden),
         :ok <- checkpoint(options, :publication_sealed),
         :ok <- File.rename(hidden, final_path),
         :ok <- Filesystem.sync_directory(parent) do
      :ok
    else
      {:error, :eexist} ->
        {:error, invalid(:artifact, :artifact_changed, "Artifact publication collided")}

      {:error, _reason} ->
        {:error, invalid(:artifact, :seal_failed, "Artifact could not be published atomically")}
    end
  end

  defp reuse_artifact(staging_path, final_path, target, descriptor) do
    with :ok <- validate_tree(final_path, target, descriptor, true),
         :ok <- Filesystem.remove_tree(staging_path) do
      :ok
    end
  end

  defp write_seal_metadata(state, target, descriptor, options) do
    path = seal_path(state, target, descriptor.artifact_id)

    case read_canonical(path) do
      {:ok, existing} ->
        if existing == descriptor_record(target, descriptor),
          do: :ok,
          else: {:error, invalid(:artifact, :artifact_changed, "Seal metadata changed")}

      :none ->
        Filesystem.atomic_write(path, descriptor_record(target, descriptor), :seal_metadata,
          checkpoint: Keyword.get(options, :checkpoint)
        )

      {:error, _} = error ->
        error
    end
  end

  defp write_reference(state, staging, descriptor, options) do
    generation = %GenerationRef{
      target: staging.target,
      generation_id: staging.generation_id,
      artifact_id: descriptor.artifact_id,
      profile: descriptor.profile,
      manifest_digest: descriptor.manifest_digest
    }

    record = reference_record(generation, descriptor.source_revision)
    path = reference_path(state, generation.target, generation.generation_id)

    case read_canonical(path) do
      {:ok, ^record} ->
        {:ok, generation}

      {:ok, _other} ->
        {:error, invalid(:artifact, :artifact_changed, "Generation reference changed")}

      :none ->
        case Filesystem.atomic_write(path, record, :generation_reference,
               checkpoint: Keyword.get(options, :checkpoint)
             ) do
          :ok -> {:ok, generation}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp validate_generation(state, %GenerationRef{} = generation) do
    with {:ok, generation} <- GenerationRef.new(Map.from_struct(generation)),
         {:ok, record} <-
           read_canonical(reference_path(state, generation.target, generation.generation_id)),
         true <- reference_matches?(record, generation),
         {:ok, descriptor} <- load_descriptor(state, generation.target, generation.artifact_id),
         true <- descriptor.manifest_digest == generation.manifest_digest,
         true <- descriptor.profile == generation.profile,
         :ok <-
           validate_tree(
             artifact_path(state, generation.target, generation.artifact_id),
             generation.target,
             descriptor,
             true
           ) do
      {:ok, generation}
    else
      _ -> {:error, invalid(:artifact, :artifact_missing, "Generation is unavailable or invalid")}
    end
  end

  defp validate_generation(_state, _generation),
    do: {:error, invalid(:artifact, :artifact_missing, "Generation is unavailable or invalid")}

  defp generation_source_revision(state, generation, expected) do
    case read_canonical(reference_path(state, generation.target, generation.generation_id)) do
      {:ok, %{"source_revision" => ^expected}} -> :ok
      _ -> {:error, invalid(:artifact, :artifact_missing, "Generation revision is unavailable")}
    end
  end

  defp maybe_generation_source_revision(_state, _generation, :any), do: :ok

  defp maybe_generation_source_revision(state, generation, expected),
    do: generation_source_revision(state, generation, expected)

  defp pointer_record(generation, revision) do
    %{
      "v" => 1,
      "target" => Atom.to_string(generation.target),
      "generation_id" => generation.generation_id,
      "artifact_id" => generation.artifact_id,
      "manifest_digest" => generation.manifest_digest,
      "source_revision" => revision
    }
  end

  defp activate_generation(state, generation, revision, current, fallback, options) do
    candidate = pointer_record(generation, revision)

    if current == candidate do
      :ok
    else
      desired_fallback = current || fallback

      journal = %{
        "v" => 1,
        "target" => Atom.to_string(generation.target),
        "old_current" => current,
        "old_fallback" => fallback,
        "new_current" => candidate
      }

      run_activation_transaction(
        state,
        generation.target,
        journal,
        desired_fallback,
        options
      )
    end
  end

  defp run_activation_transaction(state, target, journal, desired_fallback, options) do
    path = activation_path(state.root, target)

    with :ok <- activation_atomic_write(path, journal, options, :journal, target),
         :ok <- checkpoint(options, :activation_journaled),
         :ok <-
           publish_activation_pointer(
             state,
             :fallback,
             target,
             desired_fallback,
             options,
             :fallback
           ),
         :ok <- checkpoint(options, :activation_fallback_published) do
      case publish_activation_pointer(
             state,
             :current,
             target,
             journal["new_current"],
             options,
             :current
           ) do
        :ok ->
          commit_activation(state, target, journal, desired_fallback, options)

        {:error, %Failure{} = failure} ->
          resolve_activation_write(state, target, journal, desired_fallback, failure)
      end
    else
      {:error, %Failure{} = failure} ->
        abort_activation(state, target, journal, failure)
    end
  end

  defp commit_activation(state, target, journal, desired_fallback, options) do
    _ = checkpoint(options, :activation_current_published)

    case finish_committed_activation(state, target, journal, desired_fallback) do
      :ok ->
        _ = checkpoint(options, :activation_journal_removed)
        :ok

      {:cleanup_pending, %Failure{}} ->
        :ok

      {:error, %Failure{}} ->
        # The current pointer is the commit point. The durable journal completes cleanup on restart.
        :ok
    end
  end

  defp resolve_activation_write(state, target, journal, desired_fallback, failure) do
    new_current = journal["new_current"]

    case read_pointer(state, :current, target) do
      {:ok, ^new_current} ->
        case finish_committed_activation(state, target, journal, desired_fallback) do
          :ok -> :ok
          {:cleanup_pending, %Failure{}} -> :ok
          {:error, %Failure{}} -> abort_activation(state, target, journal, failure)
        end

      {:ok, _current} ->
        abort_activation(state, target, journal, failure)

      :none ->
        abort_activation(state, target, journal, failure)

      {:error, %Failure{}} ->
        {:quarantine,
         invalid(:execution, :cleanup_unconfirmed, "Activation commit state is ambiguous")}
    end
  end

  defp abort_activation(state, target, journal, failure) do
    with :ok <- ensure_pointer(state, :current, target, journal["old_current"]),
         :ok <- ensure_pointer(state, :fallback, target, journal["old_fallback"]),
         :ok <- remove_activation_journal(state.root, target) do
      {:error, failure}
    else
      {:error, %Failure{}} ->
        {:quarantine,
         invalid(:execution, :cleanup_unconfirmed, "Activation rollback could not be confirmed")}
    end
  end

  defp finish_committed_activation(state, target, journal, desired_fallback) do
    with :ok <- ensure_pointer(state, :fallback, target, desired_fallback),
         :ok <- ensure_pointer(state, :current, target, journal["new_current"]) do
      case remove_activation_journal(state.root, target) do
        :ok -> :ok
        {:error, %Failure{} = failure} -> {:cleanup_pending, failure}
      end
    end
  end

  defp ensure_pointer(state, kind, target, desired) do
    result =
      case read_pointer(state, kind, target) do
        :none when is_nil(desired) -> :ok
        {:ok, current} when current == desired -> :ok
        :none -> publish_pointer(state, kind, target, desired)
        {:ok, _current} -> publish_pointer(state, kind, target, desired)
        {:error, %Failure{} = failure} -> {:error, failure}
      end

    with :ok <- result,
         :ok <- Filesystem.sync_directory(Path.dirname(pointer_path(state, kind, target))) do
      :ok
    end
  end

  defp publish_activation_pointer(state, kind, target, nil, _options, _write_kind),
    do: publish_pointer(state, kind, target, nil)

  defp publish_activation_pointer(state, kind, target, record, options, write_kind) do
    activation_atomic_write(
      pointer_path(state, kind, target),
      record,
      options,
      write_kind,
      target
    )
  end

  defp activation_atomic_write(path, value, options, kind, target) do
    bytes = CanonicalValue.encode!(value)
    parent = Path.dirname(path)
    digest = sha256_bytes(bytes)
    temporary = Path.join(parent, activation_temporary_name(kind, target, digest))

    result =
      try do
        with {:ok, io} <- File.open(temporary, [:write, :binary, :exclusive]),
             :ok <- prepare_activation_temporary(io, temporary, bytes, options, kind),
             :ok <- File.rename(temporary, path),
             :ok <- checkpoint(options, activation_write_checkpoint(kind, :renamed)),
             :ok <- Filesystem.sync_directory(parent),
             :ok <- checkpoint(options, activation_write_checkpoint(kind, :directory_synced)) do
          :ok
        else
          {:error, %Failure{} = failure} -> {:error, failure}
          {:error, _reason} -> activation_write_failure()
          _other -> activation_write_failure()
        end
      rescue
        _exception -> activation_write_failure()
      end

    if result != :ok, do: File.rm(temporary)
    result
  end

  defp prepare_activation_temporary(io, temporary, bytes, options, kind) do
    try do
      with :ok <- File.chmod(temporary, 0o600),
           :ok <- checkpoint(options, activation_write_checkpoint(kind, :created)),
           :ok <- IO.binwrite(io, bytes),
           :ok <- checkpoint(options, activation_write_checkpoint(kind, :written)),
           :ok <- :file.sync(io),
           :ok <- checkpoint(options, activation_write_checkpoint(kind, :file_synced)) do
        :ok
      end
    after
      File.close(io)
    end
  end

  defp activation_write_checkpoint(kind, boundary),
    do: @activation_write_checkpoints |> Map.fetch!(kind) |> Map.fetch!(boundary)

  defp activation_temporary_name(kind, target, digest) do
    ".rekindle-activation-v1-#{kind}-#{target}-#{Filesystem.random_id()}-#{digest}.tmp"
  end

  defp activation_write_failure,
    do: {:error, invalid(:execution, :io_failed, "Activation record could not be published")}

  defp publish_pointer(state, kind, target, nil) do
    path = pointer_path(state, kind, target)

    with :ok <- remove_file(path),
         :ok <- Filesystem.sync_directory(Path.dirname(path)) do
      :ok
    end
  end

  defp publish_pointer(state, kind, target, record) do
    Filesystem.atomic_write(pointer_path(state, kind, target), record, :rollback_pointer)
  end

  defp pointer_value(state, kind, target) do
    case pointer_entry(state, kind, target) do
      :none -> {:ok, nil}
      {:ok, record, _generation} -> {:ok, record}
      {:error, %Failure{} = failure} -> {:quarantine, failure}
    end
  end

  defp valid_activation_options?(options),
    do: Keyword.keyword?(options) and Keyword.keys(options) -- [:checkpoint] == []

  defp pointer_generation(state, kind, target) when target in [:web, :desktop] do
    case pointer_entry(state, kind, target) do
      :none ->
        :none

      {:ok, _record, reference} ->
        case validate_generation(state, reference) do
          {:ok, generation} -> {:ok, generation}
          {:error, %Failure{} = failure} -> {:error, failure}
        end

      {:error, %Failure{} = failure} ->
        {:error, failure}
    end
  end

  defp pointer_generation(_state, _kind, _target), do: :none

  defp pointer_reply(state, kind, target) do
    with :ok <- usable(state) do
      case pointer_generation(state, kind, target) do
        {:error, %Failure{} = failure} ->
          {:reply, {:error, failure}, %{state | quarantined?: true}}

        result ->
          {:reply, result, state}
      end
    else
      {:error, %Failure{} = failure} -> {:reply, {:error, failure}, state}
    end
  end

  defp pointer_entry(state, kind, target) do
    case read_pointer(state, kind, target) do
      :none ->
        :none

      {:ok, record} ->
        with {:ok, reference} <- reference_from_record(state, record) do
          {:ok, record, reference}
        end

      {:error, %Failure{} = failure} ->
        {:error, failure}
    end
  end

  defp read_pointer(state, kind, target) do
    case read_canonical(pointer_path(state, kind, target)) do
      {:ok, record} ->
        if valid_pointer?(record, target), do: {:ok, record}, else: invalid_record()

      other ->
        other
    end
  end

  defp reference_from_record(state, record) do
    target = target_atom(record["target"])

    with target when target in [:web, :desktop] <- target,
         {:ok, reference} <-
           read_canonical(reference_path(state, target, record["generation_id"])),
         {:ok, generation} <- generation_from_reference(reference),
         true <- generation.artifact_id == record["artifact_id"],
         true <- generation.manifest_digest == record["manifest_digest"] do
      {:ok, generation}
    else
      _ -> invalid_record()
    end
  end

  defp protected_generations(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, MapSet.new()}, fn value, {:ok, acc} ->
      case GenerationRef.new(Map.from_struct(value)) do
        {:ok, generation} ->
          {:cont, {:ok, MapSet.put(acc, generation.generation_id)}}

        _ ->
          {:halt,
           {:error, invalid(:configuration, :config_invalid, "Protected generation is invalid")}}
      end
    end)
  rescue
    _ -> {:error, invalid(:configuration, :config_invalid, "Protected generation is invalid")}
  end

  defp protected_generations(_values),
    do: {:error, invalid(:configuration, :config_invalid, "Protected generations are invalid")}

  defp collect_unreferenced(state, protected, options) do
    with {:ok, references} <- all_references(state),
         {:ok, protected} <- protect_pointer(protected, state, :current),
         {:ok, protected} <- protect_pointer(protected, state, :fallback) do
      protected = protect_leases(protected, state)

      inactive =
        references
        |> Enum.reject(&MapSet.member?(protected, &1.generation.generation_id))
        |> Enum.sort_by(&{&1.published_at_unix_ms, &1.generation.generation_id})

      total_bytes = total_artifact_bytes(state, references)

      with {:ok, removed, remaining_bytes} <-
             prune(state, inactive, references, total_bytes, protected, options) do
        {:ok,
         %{
           removed_generations: length(removed),
           removed_bytes: max(total_bytes - remaining_bytes, 0),
           retained_generations: length(references) - length(removed),
           retained_bytes: remaining_bytes
         }}
      end
    else
      {:quarantine, %Failure{} = failure} -> {:quarantine, failure}
      {:error, %Failure{} = failure} -> {:error, failure}
    end
  end

  defp prune(state, inactive, references, total_bytes, protected, options) do
    Enum.reduce_while(inactive, {:ok, [], total_bytes, references}, fn candidate,
                                                                       {:ok, removed, bytes, refs} ->
      inactive_count =
        Enum.count(refs, &(not MapSet.member?(protected, &1.generation.generation_id)))

      if inactive_count > state.retained_generations or bytes > state.max_generation_bytes do
        generation = candidate.generation
        remaining = Enum.reject(refs, &(&1.generation.generation_id == generation.generation_id))

        case delete_generation(state, generation, remaining, protected, options) do
          {:ok, reclaimed} ->
            {:cont, {:ok, [generation | removed], max(bytes - reclaimed, 0), remaining}}

          {:error, _} = error ->
            {:halt, error}
        end
      else
        {:halt, {:ok, removed, bytes, refs}}
      end
    end)
    |> case do
      {:ok, removed, bytes, _refs} -> {:ok, Enum.reverse(removed), bytes}
      {:error, _} = error -> error
    end
  end

  defp delete_generation(state, generation, references, protected, options) do
    journal = %{
      "v" => 1,
      "target" => Atom.to_string(generation.target),
      "generation_id" => generation.generation_id,
      "artifact_id" => generation.artifact_id
    }

    journal_path = deletion_path(state, generation.generation_id)
    reference = reference_path(state, generation.target, generation.generation_id)

    with :ok <-
           Filesystem.atomic_write(journal_path, journal, :deletion_journal,
             checkpoint: Keyword.get(options, :checkpoint)
           ),
         :ok <- checkpoint(options, :deletion_journaled),
         :ok <- remove_file(reference),
         :ok <- Filesystem.sync_directory(Path.dirname(reference)),
         :ok <- checkpoint(options, :reference_deleted),
         {:ok, reclaimed} <- maybe_delete_artifact(state, generation, references, protected),
         :ok <- checkpoint(options, :artifact_deleted),
         :ok <- remove_file(journal_path),
         :ok <- Filesystem.sync_directory(Path.dirname(journal_path)) do
      {:ok, reclaimed}
    end
  end

  defp maybe_delete_artifact(state, generation, references, protected) do
    still_referenced? =
      Enum.any?(references, &(&1.generation.artifact_id == generation.artifact_id)) or
        Enum.any?(state.leases, fn {_token, entry} ->
          entry.lease.artifact_id == generation.artifact_id
        end) or
        Enum.any?(references, fn reference ->
          MapSet.member?(protected, reference.generation.generation_id) and
            reference.generation.artifact_id == generation.artifact_id
        end)

    if still_referenced? do
      {:ok, 0}
    else
      path = artifact_path(state, generation.target, generation.artifact_id)
      bytes = artifact_bytes(path)

      with :ok <- make_tree_writable(path),
           :ok <- Filesystem.remove_tree(path),
           :ok <- remove_file(seal_path(state, generation.target, generation.artifact_id)),
           :ok <- Filesystem.sync_directory(Path.dirname(path)),
           :ok <-
             Filesystem.sync_directory(
               Path.dirname(seal_path(state, generation.target, generation.artifact_id))
             ) do
        {:ok, bytes}
      end
    end
  end

  defp all_references(state) do
    Enum.reduce_while([:web, :desktop], {:ok, []}, fn target, {:ok, acc} ->
      directory = Path.join([state.root, "references", Atom.to_string(target)])

      case File.ls(directory) do
        {:ok, names} ->
          result =
            Enum.sort(names)
            |> Enum.reduce_while({:ok, acc}, fn name, {:ok, refs} ->
              path = Path.join(directory, name)

              with true <- Regex.match?(~r/\A[0-9a-f]{32}\.json\z/, name),
                   {:ok, record} <- read_canonical(path),
                   {:ok, generation} <- generation_from_reference(record),
                   true <- generation.target == target,
                   true <- String.trim_trailing(name, ".json") == generation.generation_id,
                   published when is_integer(published) <- record["published_at_unix_ms"] do
                {:cont,
                 {:ok, [%{generation: generation, published_at_unix_ms: published} | refs]}}
              else
                _ ->
                  {:halt,
                   {:error,
                    invalid(:artifact, :cache_corrupt, "Generation reference state is invalid")}}
              end
            end)

          case result do
            {:ok, refs} -> {:cont, {:ok, refs}}
            {:error, _} = error -> {:halt, error}
          end

        {:error, _reason} ->
          {:halt,
           {:error, invalid(:execution, :io_failed, "Generation references could not be listed")}}
      end
    end)
  end

  defp protect_pointer(protected, state, kind) do
    Enum.reduce_while([:web, :desktop], {:ok, protected}, fn target, {:ok, acc} ->
      case pointer_entry(state, kind, target) do
        :none -> {:cont, {:ok, acc}}
        {:ok, _record, generation} -> {:cont, {:ok, MapSet.put(acc, generation.generation_id)}}
        {:error, %Failure{} = failure} -> {:halt, {:quarantine, failure}}
      end
    end)
  end

  defp protect_leases(protected, state) do
    Enum.reduce(state.leases, protected, fn {_token, entry}, acc ->
      MapSet.put(acc, entry.lease.generation_id)
    end)
  end

  defp total_artifact_bytes(state, references) do
    references
    |> Enum.uniq_by(&{&1.generation.target, &1.generation.artifact_id})
    |> Enum.reduce(0, fn reference, total ->
      total +
        artifact_bytes(
          artifact_path(state, reference.generation.target, reference.generation.artifact_id)
        )
    end)
  end

  defp artifact_bytes(path) do
    case File.ls(path) do
      {:ok, names} ->
        Enum.reduce(names, 0, fn name, total ->
          child = Path.join(path, name)

          case File.lstat(child) do
            {:ok, %File.Stat{type: :regular, size: size}} -> total + size
            {:ok, %File.Stat{type: :directory}} -> total + artifact_bytes(child)
            _ -> total
          end
        end)

      _ ->
        0
    end
  end

  defp make_tree_writable(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok = File.chmod(path, 0o700)
        Enum.each(File.ls!(path), &make_tree_writable(Path.join(path, &1)))
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        File.chmod(path, 0o600)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp recover(root) do
    if quarantine_control_present?(root) do
      {:ok, true}
    else
      case recover_staging(root) do
        :ok ->
          case recover_activation_temporaries(root) do
            :ok ->
              case recover_activations(root) do
                :ok ->
                  case recover_deletions(root) do
                    :ok -> validate_persisted_state(root)
                    {:error, %Failure{} = failure} -> quarantine(root, failure.message)
                  end

                {:error, %Failure{} = failure} ->
                  quarantine(root, failure.message)
              end

            {:error, %Failure{} = failure} ->
              quarantine(root, failure.message)
          end

        {:error, %Failure{} = failure} ->
          quarantine(root, failure.message)
      end
    end
  end

  defp recover_temporaries_before_identity(root) do
    if quarantine_control_present?(root) do
      {:ok, true}
    else
      result =
        with {:ok, activation_entries} <- activation_temporary_entries(root),
             :ok <- validate_activation_temporaries(root, activation_entries),
             :ok <- recover_state_temporaries(root, activation_entries) do
          :ok
        end

      case result do
        :ok -> {:ok, false}
        {:error, %Failure{} = failure} -> quarantine(root, failure.message)
      end
    end
  end

  defp quarantine_control_present?(root) do
    case File.lstat(Path.join(root, "quarantine-v1.json")) do
      {:error, :enoent} -> false
      _present_or_ambiguous -> true
    end
  end

  defp recover_state_temporaries(root, activation_entries) do
    with {:ok, directories} <- state_temporary_directories(root),
         {:ok, entries} <- state_temporary_entries(directories),
         :ok <- validate_state_temporaries(root, entries),
         :ok <- validate_temporary_mechanism_conflicts(entries, activation_entries),
         :ok <- resolve_state_temporaries(entries) do
      :ok
    end
  end

  defp validate_temporary_mechanism_conflicts(state_entries, activation_entries) do
    conflicts? =
      Enum.any?(state_entries, fn
        %{kind: :rollback_pointer, location: kind, destination: destination} ->
          target = destination |> String.trim_trailing(".json") |> target_atom()
          Enum.any?(activation_entries, &(&1.kind == kind and &1.target == target))

        _entry ->
          false
      end)

    if conflicts?,
      do: state_temporary_failure("Artifact record temporaries conflict"),
      else: :ok
  end

  defp state_temporary_directories(root) do
    fixed =
      [
        {root, :root},
        {Path.join(root, "current"), :current},
        {Path.join(root, "fallback"), :fallback},
        {Path.join(root, "deletions"), :deletions}
      ] ++
        for(parent <- [:seals, :references], target <- [:web, :desktop]) do
          {Path.join([root, Atom.to_string(parent), Atom.to_string(target)]), {parent, target}}
        end

    staging = Path.join(root, "staging")

    with {:ok, names} <- File.ls(staging) do
      attempts =
        Enum.flat_map(names, fn name ->
          path = Path.join(staging, name)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} -> [{path, {:staging, name}}]
            _ -> []
          end
        end)

      {:ok, fixed ++ attempts}
    else
      _ -> state_temporary_failure("Artifact staging state could not be listed")
    end
  end

  defp state_temporary_entries(directories) do
    Enum.reduce_while(directories, {:ok, []}, fn {directory, location}, {:ok, entries} ->
      case File.ls(directory) do
        {:ok, names} ->
          case classify_state_temporary_names(directory, location, names) do
            {:ok, found} -> {:cont, {:ok, found ++ entries}}
            {:error, _} = error -> {:halt, error}
          end

        {:error, _reason} ->
          {:halt, state_temporary_failure("Artifact record state could not be listed")}
      end
    end)
  end

  defp classify_state_temporary_names(directory, location, names) do
    Enum.reduce_while(Enum.sort(names), {:ok, []}, fn name, {:ok, entries} ->
      if state_temporary_candidate?(location, name) do
        case Filesystem.parse_state_temporary(name) do
          {:ok, parsed} ->
            entry =
              parsed
              |> Map.merge(%{
                directory: directory,
                location: location,
                name: name,
                path: Path.join(directory, name),
                destination_path: Path.join(directory, parsed.destination)
              })

            {:cont, {:ok, [entry | entries]}}

          :error ->
            {:halt, state_temporary_failure("Artifact record temporary is ambiguous")}
        end
      else
        {:cont, {:ok, entries}}
      end
    end)
  end

  defp state_temporary_candidate?(location, ".rekindle-activation-v1-" <> _rest)
       when location in [:current, :fallback],
       do: false

  defp state_temporary_candidate?(_location, name),
    do: String.starts_with?(name, ".rekindle-state-") or String.ends_with?(name, ".tmp")

  defp validate_state_temporaries(root, entries) do
    unique_destinations? =
      entries
      |> Enum.map(& &1.destination_path)
      |> then(&(length(&1) == length(Enum.uniq(&1))))

    with true <- unique_destinations? do
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        case validate_state_temporary(root, entry) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      _ -> state_temporary_failure("Artifact record temporaries conflict")
    end
  end

  defp validate_state_temporary(root, entry) do
    with :ok <- qualify_private_file(entry.path),
         :ok <- validate_state_destination(entry),
         {:ok, bytes} <- read_state_temporary(entry.path),
         true <- bytes == "" or Filesystem.sha256_bytes(bytes) == entry.digest,
         {:ok, record} <- decode_state_temporary(bytes, entry.kind),
         :ok <- validate_state_temporary_record(root, entry, record),
         :ok <- validate_state_destination_presence(entry) do
      :ok
    else
      _ -> state_temporary_failure("Artifact record temporary is invalid")
    end
  end

  defp validate_state_destination(%{
         location: :root,
         kind: :project_id,
         destination: "project-id"
       }),
       do: :ok

  defp validate_state_destination(%{
         location: :root,
         kind: :quarantine,
         destination: "quarantine-v1.json"
       }),
       do: :ok

  defp validate_state_destination(%{location: location, kind: :rollback_pointer} = entry)
       when location in [:current, :fallback] do
    if entry.destination in ["web.json", "desktop.json"], do: :ok, else: :error
  end

  defp validate_state_destination(%{location: :deletions, kind: :deletion_journal} = entry) do
    if Regex.match?(~r/\A[0-9a-f]{32}\.json\z/, entry.destination), do: :ok, else: :error
  end

  defp validate_state_destination(%{location: {:seals, _target}, kind: :seal_metadata} = entry) do
    if Regex.match?(~r/\A[0-9a-f]{64}\.json\z/, entry.destination), do: :ok, else: :error
  end

  defp validate_state_destination(
         %{
           location: {:references, _target},
           kind: :generation_reference
         } = entry
       ) do
    if Regex.match?(~r/\A[0-9a-f]{32}\.json\z/, entry.destination), do: :ok, else: :error
  end

  defp validate_state_destination(%{location: {:staging, attempt_id}} = entry) do
    cond do
      not id?(attempt_id) -> :error
      entry.kind == :attempt_marker and entry.destination == "attempt-v1.json" -> :ok
      entry.kind == :seal_journal and entry.destination == "seal-v1.json" -> :ok
      true -> :error
    end
  end

  defp validate_state_destination(_entry), do: :error

  defp read_state_temporary(path) do
    with :ok <- qualify_private_file(path),
         {:ok, bytes} when byte_size(bytes) <= @manifest_limit <- File.read(path) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp decode_state_temporary("", _kind), do: {:ok, :empty}

  defp decode_state_temporary(bytes, :project_id), do: {:ok, bytes}

  defp decode_state_temporary(bytes, _kind) do
    with {:ok, record} when is_map(record) <- Jason.decode(bytes),
         true <- CanonicalValue.encode!(record) == bytes do
      {:ok, record}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp validate_state_temporary_record(root, %{kind: :project_id} = entry, :empty) do
    if File.exists?(entry.destination_path),
      do: :error,
      else: validate_first_start_project_identity(root, entry)
  end

  defp validate_state_temporary_record(root, %{kind: :project_id} = entry, project_id) do
    with true <- id?(project_id),
         :ok <- validate_project_identity_destination(root, entry, project_id) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_state_temporary_record(_root, %{kind: :attempt_marker} = entry, :empty),
    do: validate_unmarked_attempt(entry)

  defp validate_state_temporary_record(_root, %{kind: :attempt_marker} = entry, marker) do
    if valid_marker?(marker, elem(entry.location, 1)),
      do: validate_unmarked_attempt(entry),
      else: :error
  end

  defp validate_state_temporary_record(root, %{kind: :seal_journal} = entry, :empty),
    do: validate_seal_journal_context(root, entry, nil)

  defp validate_state_temporary_record(root, %{kind: :seal_journal} = entry, journal),
    do: validate_seal_journal_context(root, entry, journal)

  defp validate_state_temporary_record(root, %{kind: :seal_metadata} = entry, :empty),
    do: matching_publication_journal?(root, entry, nil)

  defp validate_state_temporary_record(root, %{kind: :seal_metadata} = entry, record) do
    with {:seals, target} <- entry.location,
         true <- Map.keys(record) |> Enum.sort() == ~w[descriptor target v] |> Enum.sort(),
         true <- record["v"] == 1 and record["target"] == Atom.to_string(target),
         {:ok, descriptor} <- descriptor_from_artifact_record(record["descriptor"]),
         :ok <- validate_descriptor(target, descriptor),
         true <- entry.destination == descriptor.artifact_id <> ".json",
         :ok <- matching_publication_journal?(root, entry, record) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_state_temporary_record(root, %{kind: :generation_reference} = entry, :empty),
    do: matching_publication_journal?(root, entry, nil)

  defp validate_state_temporary_record(root, %{kind: :generation_reference} = entry, record) do
    with {:references, target} <- entry.location,
         {:ok, generation} <- generation_from_reference(record),
         true <- generation.target == target,
         true <- entry.destination == generation.generation_id <> ".json",
         :ok <- matching_publication_journal?(root, entry, record) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_state_temporary_record(root, %{kind: :rollback_pointer} = entry, :empty),
    do: validate_rollback_temporary(root, entry, nil)

  defp validate_state_temporary_record(root, %{kind: :rollback_pointer} = entry, record),
    do: validate_rollback_temporary(root, entry, record)

  defp validate_state_temporary_record(_root, %{kind: :deletion_journal} = entry, :empty),
    do: validate_deletion_temporary_context(entry, nil)

  defp validate_state_temporary_record(_root, %{kind: :deletion_journal} = entry, record),
    do: validate_deletion_temporary_context(entry, record)

  defp validate_state_temporary_record(_root, %{kind: :quarantine}, :empty), do: :ok

  defp validate_state_temporary_record(_root, %{kind: :quarantine}, record) do
    if is_map(record) and Map.keys(record) |> Enum.sort() == ~w[reason state v] and
         record["v"] == 1 and record["state"] == "cleanup_required" and
         is_binary(record["reason"]),
       do: :ok,
       else: :error
  end

  defp validate_state_temporary_record(_root, _entry, _record), do: :error

  defp validate_project_identity_destination(root, entry, project_id) do
    case File.lstat(entry.destination_path) do
      {:error, :enoent} ->
        validate_first_start_project_identity(root, entry)

      {:ok, _stat} ->
        with :ok <- qualify_private_file(entry.destination_path),
             {:ok, ^project_id} <- File.read(entry.destination_path) do
          :ok
        else
          _ -> :error
        end

      _present_or_ambiguous ->
        :error
    end
  end

  defp validate_first_start_project_identity(root, entry) do
    validate_first_start_layout(root, [entry.name])
  end

  defp validate_first_start_layout(root, additional_entries) do
    root_entries =
      ~w[activations current deletions fallback generations references seals staging] ++
        additional_entries

    empty_directories =
      ~w[activations current deletions fallback staging] ++
        for(parent <- ~w[generations references seals], target <- ~w[web desktop]) do
          Path.join(parent, target)
        end

    with {:ok, names} <- File.ls(root),
         true <- Enum.sort(names) == Enum.sort(root_entries),
         :ok <- validate_first_start_container(root, "generations"),
         :ok <- validate_first_start_container(root, "references"),
         :ok <- validate_first_start_container(root, "seals"),
         true <-
           Enum.all?(empty_directories, fn relative ->
             case File.ls(Path.join(root, relative)) do
               {:ok, []} -> true
               _ -> false
             end
           end) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_first_start_container(root, relative) do
    case File.ls(Path.join(root, relative)) do
      {:ok, names} when length(names) == 2 ->
        if Enum.sort(names) == ["desktop", "web"], do: :ok, else: :error

      _ ->
        :error
    end
  end

  defp validate_unmarked_attempt(entry) do
    body = Path.join(entry.directory, "body")

    with {:ok, names} <- File.ls(entry.directory),
         true <- Enum.sort(names) == Enum.sort(["body", entry.name]),
         {:ok, %File.Stat{type: :directory, mode: attempt_mode}} <- File.lstat(entry.directory),
         true <- (attempt_mode &&& 0o777) == 0o700,
         {:ok, %File.Stat{type: :directory, mode: body_mode}} <- File.lstat(body),
         true <- (body_mode &&& 0o777) == 0o700,
         {:ok, []} <- File.ls(body) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_seal_journal_context(root, entry, journal) do
    attempt_id = elem(entry.location, 1)

    with {:ok, marker} <- read_canonical(Path.join(entry.directory, "attempt-v1.json")),
         true <- valid_marker?(marker, attempt_id),
         :ok <- validate_optional_seal_journal(marker, journal),
         true <- File.dir?(Path.join(entry.directory, "body")),
         true <- Path.dirname(entry.directory) == Path.join(root, "staging") do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_optional_seal_journal(_marker, nil), do: :ok

  defp validate_optional_seal_journal(marker, journal) do
    with true <-
           Map.keys(journal) |> Enum.sort() ==
             ~w[descriptor generation_id target v] |> Enum.sort(),
         true <- journal["v"] == 1,
         true <- journal["target"] == marker["target"],
         true <- journal["generation_id"] == marker["generation_id"],
         {:ok, target} <- target(journal["target"]),
         {:ok, descriptor} <- descriptor_from_record(journal["descriptor"]),
         :ok <- validate_descriptor(target, descriptor) do
      :ok
    else
      _ -> :error
    end
  end

  defp matching_publication_journal?(root, entry, record) do
    staging = Path.join(root, "staging")

    with {:ok, names} <- File.ls(staging) do
      if Enum.any?(names, &publication_journal_matches?(root, &1, entry, record)),
        do: :ok,
        else: :error
    else
      _ -> :error
    end
  end

  defp publication_journal_matches?(root, attempt_id, entry, record) do
    attempt = Path.join([root, "staging", attempt_id])

    with true <- id?(attempt_id),
         {:ok, marker} <- read_canonical(Path.join(attempt, "attempt-v1.json")),
         true <- valid_marker?(marker, attempt_id),
         {:ok, journal} <- read_canonical(Path.join(attempt, "seal-v1.json")),
         :ok <- validate_optional_seal_journal(marker, journal),
         true <- publication_entry_matches?(entry, record, journal),
         :ok <- validate_publication_phase(root, entry, journal) do
      true
    else
      _ -> false
    end
  end

  defp publication_entry_matches?(%{location: {:seals, target}} = entry, record, journal) do
    artifact_id = String.trim_trailing(entry.destination, ".json")

    journal["target"] == Atom.to_string(target) and
      journal["descriptor"]["artifact_id"] == artifact_id and
      (is_nil(record) or
         Map.delete(journal["descriptor"], "source_revision") == record["descriptor"])
  end

  defp publication_entry_matches?(%{location: {:references, target}} = entry, record, journal) do
    generation_id = String.trim_trailing(entry.destination, ".json")

    journal["target"] == Atom.to_string(target) and journal["generation_id"] == generation_id and
      (is_nil(record) or
         (record["artifact_id"] == journal["descriptor"]["artifact_id"] and
            record["manifest_digest"] == journal["descriptor"]["manifest_digest"] and
            record["profile"] == journal["descriptor"]["profile"] and
            record["source_revision"] == journal["descriptor"]["source_revision"]))
  end

  defp validate_publication_phase(root, entry, journal) do
    with {:ok, target} <- target(journal["target"]),
         {:ok, descriptor} <- descriptor_from_record(journal["descriptor"]),
         :ok <- validate_descriptor(target, descriptor),
         artifact =
           Path.join([root, "generations", Atom.to_string(target), descriptor.artifact_id]),
         :ok <- validate_tree(artifact, target, descriptor, true),
         :ok <- validate_publication_metadata(root, entry, target, descriptor) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_publication_metadata(_root, %{location: {:seals, target}}, target, _descriptor),
    do: :ok

  defp validate_publication_metadata(
         root,
         %{location: {:references, target}},
         target,
         descriptor
       ) do
    path = Path.join([root, "seals", Atom.to_string(target), descriptor.artifact_id <> ".json"])
    expected = descriptor_record(target, descriptor)

    with :ok <- qualify_private_file(path),
         {:ok, ^expected} <- read_canonical(path) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_rollback_temporary(root, entry, record) do
    target = entry.destination |> String.trim_trailing(".json") |> target_atom()
    kind = entry.location

    with true <- target in [:web, :desktop],
         {:ok, journal} <- read_canonical(activation_path(root, target)),
         true <- valid_activation_journal?(journal, target),
         true <- is_nil(record) or valid_pointer?(record, target),
         true <- is_nil(record) or record in rollback_pointer_values(journal, kind),
         :ok <- validate_rollback_destination(entry, target, journal) do
      :ok
    else
      _ -> :error
    end
  end

  defp rollback_pointer_values(journal, :current),
    do: Enum.reject([journal["old_current"], journal["new_current"]], &is_nil/1)

  defp rollback_pointer_values(journal, :fallback),
    do: Enum.reject([journal["old_fallback"], journal["old_current"]], &is_nil/1)

  defp validate_rollback_destination(entry, target, journal) do
    case read_canonical(entry.destination_path) do
      :none ->
        :ok

      {:ok, pointer} ->
        with :ok <- qualify_private_file(entry.destination_path),
             true <- valid_pointer?(pointer, target),
             true <- pointer in rollback_pointer_values(journal, entry.location) do
          :ok
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp validate_deletion_temporary_context(entry, record) do
    name = entry.destination

    with true <- is_nil(record) or valid_deletion_record?(record, name),
         true <- deletion_reference_matches?(entry, record) do
      :ok
    else
      _ -> :error
    end
  end

  defp deletion_reference_matches?(entry, nil) do
    generation_id = String.trim_trailing(entry.destination, ".json")
    root = entry.directory |> Path.dirname()

    existing =
      Enum.filter([:web, :desktop], fn target ->
        path = Path.join([root, "references", Atom.to_string(target), generation_id <> ".json"])

        case File.lstat(path) do
          {:ok, _stat} -> true
          {:error, :enoent} -> false
          _ -> true
        end
      end)

    case existing do
      [target] -> valid_deletion_reference?(root, target, generation_id, nil)
      _ -> false
    end
  end

  defp deletion_reference_matches?(entry, record) do
    root = entry.directory |> Path.dirname()
    target = target_atom(record["target"])

    target in [:web, :desktop] and
      valid_deletion_reference?(
        root,
        target,
        record["generation_id"],
        record["artifact_id"]
      )
  end

  defp valid_deletion_reference?(root, target, generation_id, expected_artifact_id) do
    path = Path.join([root, "references", Atom.to_string(target), generation_id <> ".json"])

    with :ok <- qualify_private_file(path),
         {:ok, reference} <- read_canonical(path),
         {:ok, generation} <- generation_from_reference(reference),
         true <- generation.target == target,
         true <- generation.generation_id == generation_id,
         true <- is_nil(expected_artifact_id) or generation.artifact_id == expected_artifact_id do
      true
    else
      _ -> false
    end
  end

  defp validate_state_destination_presence(%{kind: :rollback_pointer}), do: :ok

  defp validate_state_destination_presence(%{kind: :project_id, destination_path: path}) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> qualify_private_file(path)
      {:error, :enoent} -> :ok
      _ -> :error
    end
  end

  defp validate_state_destination_presence(%{destination_path: path}) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _ -> :error
    end
  end

  defp resolve_state_temporaries(entries) do
    entries
    |> Enum.group_by(&state_temporary_resolution/1)
    |> Enum.reduce_while(:ok, fn
      {{:attempt, directory}, _group}, :ok ->
        case Filesystem.remove_tree(directory) do
          :ok ->
            case Filesystem.sync_directory(Path.dirname(directory)) do
              :ok -> {:cont, :ok}
              _ -> {:halt, state_temporary_failure("Artifact record recovery was not durable")}
            end

          _ ->
            {:halt, state_temporary_failure("Artifact record temporary could not be removed")}
        end

      {{:project_id, destination}, [entry]}, :ok ->
        case read_state_temporary(entry.path) do
          {:ok, ""} ->
            resolve_removed_state_temporary(entry)

          {:ok, _project_id} ->
            if File.exists?(destination) do
              resolve_removed_state_temporary(entry)
            else
              case File.rename(entry.path, destination) do
                :ok ->
                  case Filesystem.sync_directory(entry.directory) do
                    :ok ->
                      {:cont, :ok}

                    _ ->
                      {:halt,
                       state_temporary_failure("Project identity recovery was not durable")}
                  end

                _ ->
                  {:halt, state_temporary_failure("Project identity could not be restored")}
              end
            end

          _ ->
            {:halt, state_temporary_failure("Project identity could not be restored")}
        end

      {{:quarantine, destination}, [entry]}, :ok ->
        case read_state_temporary(entry.path) do
          {:ok, ""} ->
            with :ok <- remove_state_temporary(entry),
                 :ok <- Filesystem.sync_directory(entry.directory) do
              {:halt, state_temporary_failure("Interrupted quarantine publication was recovered")}
            else
              _ ->
                {:halt, state_temporary_failure("Artifact record temporary could not be removed")}
            end

          {:ok, _bytes} ->
            with :ok <- File.rename(entry.path, destination),
                 :ok <- Filesystem.sync_directory(entry.directory) do
              {:halt, state_temporary_failure("Artifact store requires explicit cleanup")}
            else
              _ -> {:halt, state_temporary_failure("Artifact quarantine could not be restored")}
            end

          _ ->
            {:halt, state_temporary_failure("Artifact quarantine could not be restored")}
        end

      {{:files, directory}, group}, :ok ->
        with :ok <- remove_state_temporary_files(group),
             :ok <- Filesystem.sync_directory(directory) do
          {:cont, :ok}
        else
          _ -> {:halt, state_temporary_failure("Artifact record temporary could not be removed")}
        end
    end)
  end

  defp state_temporary_resolution(%{
         kind: :attempt_marker,
         destination_path: destination,
         directory: directory
       }) do
    if File.exists?(destination), do: {:files, directory}, else: {:attempt, directory}
  end

  defp state_temporary_resolution(%{kind: :project_id} = entry),
    do: {:project_id, entry.destination_path}

  defp state_temporary_resolution(%{kind: :quarantine} = entry),
    do: {:quarantine, entry.destination_path}

  defp state_temporary_resolution(entry), do: {:files, entry.directory}

  defp remove_state_temporary_files(entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case remove_state_temporary(entry) do
        :ok -> {:cont, :ok}
        _ -> {:halt, :error}
      end
    end)
  end

  defp remove_state_temporary(entry) do
    case File.rm(entry.path) do
      :ok -> :ok
      _ -> :error
    end
  end

  defp resolve_removed_state_temporary(entry) do
    with :ok <- remove_state_temporary(entry),
         :ok <- Filesystem.sync_directory(entry.directory) do
      {:cont, :ok}
    else
      _ -> {:halt, state_temporary_failure("Artifact record temporary could not be removed")}
    end
  end

  defp state_temporary_failure(message),
    do: {:error, invalid(:artifact, :cache_corrupt, message)}

  defp recover_activation_temporaries(root) do
    with {:ok, entries} <- activation_temporary_entries(root),
         :ok <- validate_activation_temporaries(root, entries),
         :ok <- remove_activation_temporaries(entries) do
      :ok
    end
  end

  defp activation_temporary_entries(root) do
    Enum.reduce_while(
      [journal: "activations", current: "current", fallback: "fallback"],
      {:ok, []},
      fn
        {kind, directory_name}, {:ok, entries} ->
          directory = Path.join(root, directory_name)

          case File.ls(directory) do
            {:ok, names} ->
              case classify_activation_directory(directory, kind, names) do
                {:ok, found} -> {:cont, {:ok, found ++ entries}}
                {:error, _} = error -> {:halt, error}
              end

            {:error, _reason} ->
              {:halt, activation_temporary_failure("Activation state could not be listed")}
          end
      end
    )
  end

  defp classify_activation_directory(directory, kind, names) do
    Enum.reduce_while(Enum.sort(names), {:ok, []}, fn name, {:ok, entries} ->
      cond do
        name in ["web.json", "desktop.json"] ->
          {:cont, {:ok, entries}}

        kind in [:current, :fallback] and String.starts_with?(name, ".rekindle-state-") ->
          {:cont, {:ok, entries}}

        true ->
          case parse_activation_temporary(name, kind) do
            {:ok, target, digest} ->
              entry = %{
                kind: kind,
                target: target,
                digest: digest,
                path: Path.join(directory, name)
              }

              {:cont, {:ok, [entry | entries]}}

            :error ->
              {:halt, activation_temporary_failure("Activation temporary state is ambiguous")}
          end
      end
    end)
  end

  defp parse_activation_temporary(name, kind) do
    pattern =
      ~r/\A\.rekindle-activation-v1-#{kind}-(web|desktop)-([0-9a-f]{32})-([0-9a-f]{64})\.tmp\z/

    case Regex.run(pattern, name, capture: :all_but_first) do
      [target, _transaction_id, digest] -> {:ok, target_atom(target), digest}
      _ -> :error
    end
  end

  defp validate_activation_temporaries(root, entries) do
    unique? =
      entries
      |> Enum.map(&{&1.kind, &1.target})
      |> then(&(length(&1) == length(Enum.uniq(&1))))

    if unique? do
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        case validate_activation_temporary(root, entry) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      activation_temporary_failure("Activation temporary state is ambiguous")
    end
  end

  defp validate_activation_temporary(_root, %{kind: :journal} = entry) do
    with :ok <- qualify_private_file(entry.path),
         {:ok, bytes} <- read_activation_temporary(entry.path),
         true <- valid_activation_journal_temporary?(bytes, entry.target, entry.digest) do
      :ok
    else
      _ -> activation_temporary_failure("Activation journal temporary is invalid")
    end
  end

  defp validate_activation_temporary(root, entry) when entry.kind in [:current, :fallback] do
    with :ok <- qualify_private_file(entry.path),
         {:ok, bytes} <- read_activation_temporary(entry.path),
         {:ok, journal} <- read_canonical(activation_path(root, entry.target)),
         true <- valid_activation_journal?(journal, entry.target),
         {:ok, expected} <- activation_temporary_pointer(journal, entry.kind),
         expected_bytes = CanonicalValue.encode!(expected),
         true <- entry.digest == sha256_bytes(expected_bytes),
         true <- bytes in ["", expected_bytes] do
      :ok
    else
      _ -> activation_temporary_failure("Activation pointer temporary is invalid")
    end
  end

  defp read_activation_temporary(path) do
    with :ok <- qualify_private_file(path),
         {:ok, bytes} when byte_size(bytes) <= @manifest_limit <- File.read(path) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp valid_activation_journal_temporary?("", _target, _digest), do: true

  defp valid_activation_journal_temporary?(bytes, target, digest) do
    with true <- digest == sha256_bytes(bytes),
         {:ok, journal} <- Jason.decode(bytes),
         true <- CanonicalValue.encode!(journal) == bytes do
      valid_activation_journal?(journal, target)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp activation_temporary_pointer(journal, :current), do: {:ok, journal["new_current"]}

  defp activation_temporary_pointer(journal, :fallback) do
    case journal["old_current"] || journal["old_fallback"] do
      nil -> :error
      pointer -> {:ok, pointer}
    end
  end

  defp remove_activation_temporaries(entries) do
    entries
    |> Enum.group_by(&Path.dirname(&1.path))
    |> Enum.reduce_while(:ok, fn {directory, grouped}, :ok ->
      with :ok <- remove_activation_temporary_files(grouped),
           :ok <- Filesystem.sync_directory(directory) do
        {:cont, :ok}
      else
        _ -> {:halt, activation_temporary_failure("Activation temporary could not be removed")}
      end
    end)
  end

  defp remove_activation_temporary_files(entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case File.rm(entry.path) do
        :ok -> {:cont, :ok}
        _ -> {:halt, :error}
      end
    end)
  end

  defp activation_temporary_failure(message),
    do: {:error, invalid(:artifact, :cache_corrupt, message)}

  defp recover_activations(root) do
    directory = Path.join(root, "activations")

    case File.ls(directory) do
      {:ok, names} ->
        Enum.reduce_while(Enum.sort(names), :ok, fn name, :ok ->
          case activation_target(name) do
            {:ok, target} ->
              case recover_activation(root, target) do
                :ok -> {:cont, :ok}
                {:error, _} = error -> {:halt, error}
              end

            :error ->
              {:halt,
               {:error, invalid(:artifact, :cache_corrupt, "Activation journal is invalid")}}
          end
        end)

      {:error, _reason} ->
        {:error, invalid(:execution, :io_failed, "Activation state could not be listed")}
    end
  end

  defp recover_activation(root, target) do
    state = %__MODULE__{root: root}
    path = activation_path(root, target)

    case read_canonical(path) do
      :none ->
        :ok

      {:ok, journal} ->
        with true <- valid_activation_journal?(journal, target) do
          desired_fallback = journal["old_current"] || journal["old_fallback"]
          new_current = journal["new_current"]

          case read_pointer(state, :current, target) do
            {:ok, ^new_current} ->
              case finish_committed_activation(state, target, journal, desired_fallback) do
                :ok -> :ok
                {:cleanup_pending, %Failure{} = failure} -> {:error, failure}
                {:error, %Failure{} = failure} -> {:error, failure}
              end

            {:ok, _current} ->
              rollback_recovered_activation(state, target, journal)

            :none ->
              rollback_recovered_activation(state, target, journal)

            {:error, %Failure{} = failure} ->
              {:error, failure}
          end
        else
          _ -> {:error, invalid(:artifact, :cache_corrupt, "Activation journal is invalid")}
        end

      {:error, %Failure{} = failure} ->
        {:error, failure}
    end
  end

  defp rollback_recovered_activation(state, target, journal) do
    with :ok <- ensure_pointer(state, :current, target, journal["old_current"]),
         :ok <- ensure_pointer(state, :fallback, target, journal["old_fallback"]),
         :ok <- remove_activation_journal(state.root, target) do
      :ok
    end
  end

  defp valid_activation_journal?(journal, target) do
    is_map(journal) and
      Map.keys(journal) |> Enum.sort() ==
        ~w[new_current old_current old_fallback target v] |> Enum.sort() and
      journal["v"] == 1 and journal["target"] == Atom.to_string(target) and
      optional_pointer?(journal["old_current"], target) and
      optional_pointer?(journal["old_fallback"], target) and
      valid_pointer?(journal["new_current"], target) and
      journal["old_current"] != journal["new_current"]
  end

  defp optional_pointer?(nil, _target), do: true
  defp optional_pointer?(record, target), do: valid_pointer?(record, target)

  defp activation_target("web.json"), do: {:ok, :web}
  defp activation_target("desktop.json"), do: {:ok, :desktop}
  defp activation_target(_name), do: :error

  defp recover_staging(root) do
    directory = Path.join(root, "staging")

    case File.ls(directory) do
      {:ok, names} ->
        Enum.reduce_while(Enum.sort(names), :ok, fn name, :ok ->
          path = Path.join(directory, name)

          case recover_attempt(root, path, name) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)

      {:error, _reason} ->
        {:error, invalid(:execution, :io_failed, "Staging state could not be listed")}
    end
  end

  defp recover_attempt(root, path, name) do
    marker_path = Path.join(path, "attempt-v1.json")
    journal_path = Path.join(path, "seal-v1.json")

    with true <- id?(name),
         {:ok, marker} <- read_canonical(marker_path),
         true <- valid_marker?(marker, name) do
      case read_canonical(journal_path) do
        {:ok, journal} -> recover_journaled(root, path, marker, journal)
        :none -> Filesystem.remove_tree(path)
        {:error, _} = error -> error
      end
    else
      _ -> {:error, invalid(:artifact, :cache_corrupt, "Staging ownership is ambiguous")}
    end
  end

  defp recover_journaled(root, attempt_path, marker, journal) do
    with {:ok, target} <- target(journal["target"]),
         true <- marker["target"] == journal["target"],
         true <- marker["generation_id"] == journal["generation_id"],
         {:ok, descriptor} <- descriptor_from_record(journal["descriptor"]),
         final = Path.join([root, "generations", Atom.to_string(target), descriptor.artifact_id]) do
      case recover_artifact_path(root, attempt_path, target, descriptor, final) do
        :discarded ->
          :ok

        :ok ->
          with :ok <- validate_tree(final, target, descriptor, true),
               :ok <- recover_metadata(root, target, descriptor),
               :ok <- recover_reference(root, target, marker["generation_id"], descriptor),
               :ok <- Filesystem.remove_tree(attempt_path) do
            :ok
          end

        {:error, _} = error ->
          error
      end
    else
      {:error, %Failure{} = failure} -> {:error, failure}
      _ -> {:error, invalid(:artifact, :cache_corrupt, "Interrupted publication is invalid")}
    end
  end

  defp recover_artifact_path(root, attempt_path, target, descriptor, final) do
    parent = Path.join([root, "generations", Atom.to_string(target)])
    attempt_id = Path.basename(attempt_path)
    hidden = Path.join(parent, ".#{descriptor.artifact_id}.#{attempt_id}.publishing")
    body = Path.join(attempt_path, "body")

    cond do
      File.dir?(final) ->
        :ok

      File.dir?(hidden) ->
        with :ok <- validate_tree(hidden, target, descriptor, false),
             :ok <- File.chmod(hidden, 0o500),
             :ok <- Filesystem.sync_directory(hidden),
             :ok <- File.rename(hidden, final),
             :ok <- Filesystem.sync_directory(parent) do
          :ok
        else
          _ -> {:error, invalid(:artifact, :cache_corrupt, "Interrupted artifact is invalid")}
        end

      File.dir?(body) ->
        case Filesystem.remove_tree(attempt_path) do
          :ok -> :discarded
          {:error, _} = error -> error
        end

      true ->
        {:error, invalid(:artifact, :cache_corrupt, "Interrupted artifact is missing")}
    end
  end

  defp recover_metadata(root, target, descriptor) do
    path = Path.join([root, "seals", Atom.to_string(target), descriptor.artifact_id <> ".json"])
    record = descriptor_record(target, descriptor)

    case read_canonical(path) do
      {:ok, ^record} -> :ok
      :none -> Filesystem.atomic_write(path, record, :seal_metadata)
      _ -> {:error, invalid(:artifact, :cache_corrupt, "Seal metadata is invalid")}
    end
  end

  defp recover_reference(root, target, generation_id, descriptor) do
    generation = %GenerationRef{
      target: target,
      generation_id: generation_id,
      artifact_id: descriptor.artifact_id,
      profile: descriptor.profile,
      manifest_digest: descriptor.manifest_digest
    }

    path = Path.join([root, "references", Atom.to_string(target), generation_id <> ".json"])
    record = reference_record(generation, descriptor.source_revision)

    case read_canonical(path) do
      {:ok, existing} ->
        if reference_matches?(existing, generation) and
             existing["source_revision"] == descriptor.source_revision,
           do: :ok,
           else: invalid_record()

      :none ->
        Filesystem.atomic_write(path, record, :generation_reference)

      {:error, _} = error ->
        error
    end
  end

  defp validate_persisted_state(root) do
    temporary = %__MODULE__{root: root}

    with :ok <- validate_root_entries(root),
         :ok <- validate_control_directories(temporary),
         :ok <- validate_reference_directories(temporary),
         :ok <- validate_generation_directories(temporary),
         :ok <- validate_pointers(temporary) do
      {:ok, false}
    else
      {:error, %Failure{} = failure} -> quarantine(root, failure.message)
    end
  end

  defp validate_root_entries(root) do
    expected =
      ~w[activations current deletions fallback generations project-id references seals staging]

    case File.ls(root) do
      {:ok, names} when length(names) == length(expected) ->
        if Enum.sort(names) == expected,
          do: :ok,
          else: {:error, invalid(:artifact, :cache_corrupt, "Artifact root state is ambiguous")}

      _ ->
        {:error, invalid(:artifact, :cache_corrupt, "Artifact root state is ambiguous")}
    end
  end

  defp recover_deletions(root) do
    directory = Path.join(root, "deletions")

    case File.ls(directory) do
      {:ok, names} ->
        Enum.reduce_while(Enum.sort(names), :ok, fn name, :ok ->
          path = Path.join(directory, name)

          case recover_deletion(root, path, name) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)

      {:error, _reason} ->
        {:error, invalid(:execution, :io_failed, "Deletion state could not be listed")}
    end
  end

  defp recover_deletion(root, path, name) do
    state = %__MODULE__{root: root, leases: %{}}

    with true <- Regex.match?(~r/\A[0-9a-f]{32}\.json\z/, name),
         {:ok, record} <- read_canonical(path),
         true <- valid_deletion_record?(record, name),
         {:ok, target} <- target(record["target"]),
         {:ok, false} <- pointer_references?(state, record["generation_id"]),
         :ok <- remove_deletion_reference(state, target, record),
         {:ok, references} <- all_references(state),
         :ok <- remove_deleted_artifact(state, target, record["artifact_id"], references),
         :ok <- remove_file(path),
         :ok <- Filesystem.sync_directory(Path.dirname(path)) do
      :ok
    else
      {:error, %Failure{} = failure} -> {:error, failure}
      _ -> {:error, invalid(:artifact, :cache_corrupt, "Deletion journal is invalid")}
    end
  end

  defp remove_deletion_reference(state, target, record) do
    path = reference_path(state, target, record["generation_id"])

    case read_canonical(path) do
      :none ->
        :ok

      {:ok, reference} ->
        if reference["artifact_id"] == record["artifact_id"] and
             reference["generation_id"] == record["generation_id"] do
          with :ok <- remove_file(path),
               :ok <- Filesystem.sync_directory(Path.dirname(path)) do
            :ok
          end
        else
          invalid_record()
        end

      {:error, _} = error ->
        error
    end
  end

  defp remove_deleted_artifact(state, target, artifact_id, references) do
    if Enum.any?(references, &(&1.generation.artifact_id == artifact_id)) do
      :ok
    else
      artifact = artifact_path(state, target, artifact_id)

      with :ok <- validate_deletion_artifact(state, target, artifact_id, artifact),
           :ok <- make_tree_writable(artifact),
           :ok <- Filesystem.remove_tree(artifact),
           :ok <- remove_file(seal_path(state, target, artifact_id)),
           :ok <- Filesystem.sync_directory(Path.dirname(artifact)),
           :ok <- Filesystem.sync_directory(Path.dirname(seal_path(state, target, artifact_id))) do
        :ok
      end
    end
  end

  defp validate_deletion_artifact(state, target, artifact_id, artifact) do
    case File.lstat(artifact) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        with {:ok, descriptor} <- load_descriptor(state, target, artifact_id),
             :ok <- validate_tree(artifact, target, descriptor, true) do
          :ok
        end

      _ ->
        {:error, invalid(:artifact, :cache_corrupt, "Deleting artifact is invalid")}
    end
  end

  defp pointer_references?(state, generation_id) do
    Enum.reduce_while([:current, :fallback], {:ok, false}, fn kind, {:ok, false} ->
      Enum.reduce_while([:web, :desktop], {:ok, false}, fn target, {:ok, false} ->
        case pointer_entry(state, kind, target) do
          :none ->
            {:cont, {:ok, false}}

          {:ok, record, _generation} ->
            if record["generation_id"] == generation_id,
              do: {:halt, {:ok, true}},
              else: {:cont, {:ok, false}}

          {:error, %Failure{} = failure} ->
            {:halt, {:error, failure}}
        end
      end)
      |> case do
        {:ok, false} -> {:cont, {:ok, false}}
        result -> {:halt, result}
      end
    end)
  end

  defp valid_deletion_record?(record, name) do
    is_map(record) and
      Map.keys(record) |> Enum.sort() == ~w[artifact_id generation_id target v] |> Enum.sort() and
      record["v"] == 1 and record["target"] in ["web", "desktop"] and
      id?(record["generation_id"]) and digest?(record["artifact_id"]) and
      name == record["generation_id"] <> ".json"
  end

  defp validate_control_directories(state) do
    with :ok <- exact_record_names(Path.join(state.root, "current")),
         :ok <- exact_record_names(Path.join(state.root, "fallback")),
         {:ok, []} <- File.ls(Path.join(state.root, "activations")),
         {:ok, []} <- File.ls(Path.join(state.root, "deletions")) do
      :ok
    else
      _ -> {:error, invalid(:artifact, :cache_corrupt, "Artifact control state is ambiguous")}
    end
  end

  defp exact_record_names(directory) do
    case File.ls(directory) do
      {:ok, names} ->
        if Enum.all?(names, &(&1 in ["web.json", "desktop.json"])),
          do: :ok,
          else:
            {:error, invalid(:artifact, :cache_corrupt, "Artifact pointer state is ambiguous")}

      _ ->
        {:error, invalid(:execution, :io_failed, "Artifact pointer state could not be listed")}
    end
  end

  defp validate_generation_directories(state) do
    with {:ok, references} <- all_references(state) do
      Enum.reduce_while([:web, :desktop], :ok, fn target, :ok ->
        expected =
          references
          |> Enum.filter(&(&1.generation.target == target))
          |> Enum.map(& &1.generation.artifact_id)
          |> MapSet.new()

        generation_directory = Path.join([state.root, "generations", Atom.to_string(target)])
        seal_directory = Path.join([state.root, "seals", Atom.to_string(target)])

        with {:ok, artifacts} <- File.ls(generation_directory),
             {:ok, seals} <- File.ls(seal_directory),
             true <- Enum.all?(artifacts, &digest?/1),
             true <- Enum.all?(artifacts, &File.dir?(Path.join(generation_directory, &1))),
             true <- Enum.all?(seals, &Regex.match?(~r/\A[0-9a-f]{64}\.json\z/, &1)),
             true <- MapSet.new(artifacts) == expected,
             true <- MapSet.new(Enum.map(seals, &String.trim_trailing(&1, ".json"))) == expected do
          {:cont, :ok}
        else
          _ ->
            {:halt,
             {:error,
              invalid(:artifact, :cache_corrupt, "Artifact generation state is ambiguous")}}
        end
      end)
    end
  end

  defp validate_reference_directories(state) do
    case all_references(state) do
      {:ok, references} ->
        Enum.reduce_while(references, :ok, fn reference, :ok ->
          case validate_generation(state, reference.generation) do
            {:ok, _} -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)

      {:error, _} = error ->
        error
    end
  end

  defp validate_pointers(state) do
    Enum.reduce_while([:current, :fallback], :ok, fn kind, :ok ->
      Enum.reduce_while([:web, :desktop], :ok, fn target, :ok ->
        case pointer_entry(state, kind, target) do
          :none ->
            {:cont, :ok}

          {:ok, _record, _generation} ->
            {:cont, :ok}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
      |> case do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp quarantine(root, reason) do
    record = %{"v" => 1, "state" => "cleanup_required", "reason" => reason}

    case Filesystem.atomic_write(Path.join(root, "quarantine-v1.json"), record, :quarantine) do
      :ok -> {:ok, true}
      {:error, _} = error -> error
    end
  end

  defp descriptor_record(target, descriptor) do
    %{
      "v" => 1,
      "target" => Atom.to_string(target),
      "descriptor" => descriptor_to_map(descriptor) |> Map.delete("source_revision")
    }
  end

  defp seal_record(staging, descriptor) do
    %{
      "v" => 1,
      "target" => Atom.to_string(staging.target),
      "generation_id" => staging.generation_id,
      "descriptor" => descriptor_to_map(descriptor)
    }
  end

  defp descriptor_to_map(descriptor) do
    %{
      "artifact_id" => descriptor.artifact_id,
      "manifest_path" => descriptor.manifest_path,
      "manifest_digest" => descriptor.manifest_digest,
      "profile" => descriptor.profile,
      "source_revision" => descriptor.source_revision,
      "members" =>
        Enum.map(descriptor.members, fn member ->
          %{
            "path" => member.path,
            "sha256" => member.sha256,
            "size" => member.size,
            "mode" => Atom.to_string(member.mode)
          }
        end)
    }
  end

  defp descriptor_from_record(value) when is_map(value) do
    with true <-
           Map.keys(value) |> Enum.sort() ==
             ~w[artifact_id manifest_digest manifest_path members profile source_revision]
             |> Enum.sort(),
         members when is_list(members) <- value["members"],
         {:ok, members} <- members_from_records(members) do
      descriptor = %Descriptor{
        artifact_id: value["artifact_id"],
        manifest_path: value["manifest_path"],
        manifest_digest: value["manifest_digest"],
        profile: value["profile"],
        source_revision: value["source_revision"],
        members: members
      }

      {:ok, descriptor}
    else
      _ -> {:error, invalid(:artifact, :manifest_invalid, "Seal descriptor record is invalid")}
    end
  end

  defp descriptor_from_record(_value),
    do: {:error, invalid(:artifact, :manifest_invalid, "Seal descriptor record is invalid")}

  defp descriptor_from_artifact_record(value) when is_map(value) do
    value
    |> Map.put_new("source_revision", 0)
    |> descriptor_from_record()
  end

  defp descriptor_from_artifact_record(_value),
    do: {:error, invalid(:artifact, :manifest_invalid, "Seal descriptor record is invalid")}

  defp members_from_records(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      with true <- is_map(value),
           true <- Map.keys(value) |> Enum.sort() == ~w[mode path sha256 size] |> Enum.sort(),
           {:ok, mode} <- member_mode(value["mode"]) do
        {:cont,
         {:ok,
          [
            %Member{
              path: value["path"],
              sha256: value["sha256"],
              size: value["size"],
              mode: mode
            }
            | acc
          ]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, members} -> {:ok, Enum.reverse(members)}
      _ -> :error
    end
  end

  defp reference_record(generation, source_revision) do
    %{
      "v" => 1,
      "target" => Atom.to_string(generation.target),
      "generation_id" => generation.generation_id,
      "artifact_id" => generation.artifact_id,
      "manifest_digest" => generation.manifest_digest,
      "profile" => generation.profile,
      "source_revision" => source_revision,
      "published_at_unix_ms" => System.system_time(:millisecond)
    }
  end

  defp generation_from_reference(record) when is_map(record) do
    with true <-
           Map.keys(record) |> Enum.sort() ==
             ~w[artifact_id generation_id manifest_digest profile published_at_unix_ms source_revision target v]
             |> Enum.sort(),
         true <- record["v"] == 1,
         {:ok, target} <- target(record["target"]),
         true <- uint?(record["source_revision"]),
         true <- uint?(record["published_at_unix_ms"]),
         {:ok, generation} <-
           GenerationRef.new(
             target: target,
             generation_id: record["generation_id"],
             artifact_id: record["artifact_id"],
             profile: record["profile"],
             manifest_digest: record["manifest_digest"]
           ) do
      {:ok, generation}
    else
      _ -> invalid_record()
    end
  end

  defp generation_from_reference(_record), do: invalid_record()

  defp load_descriptor(state, target, artifact_id) do
    with {:ok, record} <- read_canonical(seal_path(state, target, artifact_id)),
         true <- Map.keys(record) |> Enum.sort() == ~w[descriptor target v] |> Enum.sort(),
         true <- record["v"] == 1,
         true <- record["target"] == Atom.to_string(target),
         {:ok, descriptor} <- descriptor_from_artifact_record(record["descriptor"]),
         :ok <- validate_descriptor(target, descriptor),
         true <- descriptor.artifact_id == artifact_id do
      {:ok, descriptor}
    else
      _ -> {:error, invalid(:artifact, :cache_corrupt, "Seal metadata is invalid")}
    end
  end

  defp read_canonical(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :none

      {:ok, _stat} ->
        with :ok <- qualify_private_file(path),
             {:ok, bytes} when byte_size(bytes) <= @manifest_limit <- File.read(path),
             {:ok, value} <- Jason.decode(bytes),
             true <- is_map(value),
             true <- CanonicalValue.encode!(value) == bytes do
          {:ok, value}
        else
          _ -> invalid_record()
        end

      _present_or_ambiguous ->
        invalid_record()
    end
  rescue
    _ -> invalid_record()
  end

  defp checkpoint(options, name) do
    case Keyword.get(options, :checkpoint) do
      nil -> :ok
      function when is_function(function, 1) -> function.(name)
      _ -> {:error, invalid(:internal, :contract_violation, "Checkpoint adapter is invalid")}
    end
  end

  defp cleanup_attempt(state, attempt_id) do
    case Map.get(state.attempts, attempt_id) do
      %{staging: staging} -> Filesystem.remove_tree(Path.dirname(staging.path))
      nil -> :ok
    end
  end

  defp drop_attempt(state, attempt_id, monitor_down?) do
    case Map.pop(state.attempts, attempt_id) do
      {nil, _attempts} ->
        state

      {%{monitor: monitor}, attempts} ->
        unless monitor_down?, do: Process.demonitor(monitor, [:flush])

        %{
          state
          | attempts: attempts,
            attempt_monitors: Map.delete(state.attempt_monitors, monitor)
        }
    end
  end

  defp drop_lease(state, token, monitor_down? \\ false) do
    case Map.pop(state.leases, token) do
      {nil, _leases} ->
        state

      {%{monitor: monitor}, leases} ->
        unless monitor_down?, do: Process.demonitor(monitor, [:flush])
        %{state | leases: leases, lease_monitors: Map.delete(state.lease_monitors, monitor)}
    end
  end

  defp usable(%{quarantined?: true}),
    do:
      {:error,
       invalid(:execution, :cleanup_unconfirmed, "Artifact store requires explicit cleanup")}

  defp usable(_state), do: :ok

  defp writable(state) do
    with :ok <- usable(state) do
      case validate_pointers(state) do
        :ok -> :ok
        {:error, %Failure{} = failure} -> {:quarantine, failure}
      end
    end
  end

  defp artifact_path(state, target, artifact_id),
    do: Path.join([state.root, "generations", Atom.to_string(target), artifact_id])

  defp reference_path(state, target, generation_id),
    do: Path.join([state.root, "references", Atom.to_string(target), generation_id <> ".json"])

  defp seal_path(state, target, artifact_id),
    do: Path.join([state.root, "seals", Atom.to_string(target), artifact_id <> ".json"])

  defp pointer_path(state, kind, target),
    do: Path.join([state.root, Atom.to_string(kind), Atom.to_string(target) <> ".json"])

  defp activation_path(root, target),
    do: Path.join([root, "activations", Atom.to_string(target) <> ".json"])

  defp remove_activation_journal(root, target) do
    path = activation_path(root, target)

    with :ok <- remove_file(path),
         :ok <- Filesystem.sync_directory(Path.dirname(path)) do
      :ok
    end
  end

  defp deletion_path(state, generation_id),
    do: Path.join([state.root, "deletions", generation_id <> ".json"])

  defp remove_file(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, _reason} ->
        {:error, invalid(:execution, :cleanup_unconfirmed, "Owned state could not be removed")}
    end
  end

  defp unique_generation_id(state, target) do
    id = Filesystem.random_id()

    if File.exists?(reference_path(state, target, id)) or
         Enum.any?(state.attempts, fn {_attempt, entry} -> entry.staging.generation_id == id end),
       do: unique_generation_id(state, target),
       else: id
  end

  defp qualify_private_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode, links: 1}}
      when (mode &&& 0o777) == 0o600 ->
        :ok

      _ ->
        {:error,
         invalid(:configuration, :path_invalid, "Private state file authority is invalid")}
    end
  end

  defp lstat_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} -> {:ok, stat}
      _ -> {:error, invalid(:artifact, :manifest_invalid, "Artifact root is not a directory")}
    end
  end

  defp same_authority?(left, right) do
    left.uid == right.uid and left.major_device == right.major_device and
      left.minor_device == right.minor_device
  end

  defp member_mode?(mode, :regular, false), do: (mode &&& 0o111) == 0
  defp member_mode?(mode, :executable_owner, false), do: (mode &&& 0o100) != 0
  defp member_mode?(mode, :regular, true), do: sealed_regular?(mode)
  defp member_mode?(mode, :executable_owner, true), do: (mode &&& 0o777) == 0o500
  defp sealed_regular?(mode), do: (mode &&& 0o777) == 0o400

  defp executable_member?(descriptor, path),
    do: Enum.any?(descriptor.members, &(&1.path == path and &1.mode == :executable_owner))

  defp valid_member?(%Member{path: path, sha256: digest, size: size, mode: mode}),
    do:
      safe_path?(path) and digest?(digest) and uint?(size) and
        mode in [:regular, :executable_owner]

  defp valid_member?(_member), do: false

  defp safe_path?(value), do: Validation.relative?(value)

  defp unique_paths?(paths) do
    keys = Enum.map(paths, &:string.casefold/1)
    length(keys) == length(Enum.uniq(keys))
  end

  defp descriptor_total_bytes(root, descriptor) do
    manifest_size =
      case File.lstat(Path.join(root, descriptor.manifest_path)) do
        {:ok, %File.Stat{type: :regular, size: size}} -> size
        _ -> @safe_integer
      end

    Enum.sum(Enum.map(descriptor.members, & &1.size)) + manifest_size
  end

  defp manifest_digest(target, manifest) do
    domain =
      case target do
        :web -> "rekindle-web-manifest-v1\0"
        :desktop -> "rekindle-native-manifest-v1\0"
      end

    :crypto.hash(
      :sha256,
      domain <> CanonicalValue.encode!(Map.delete(manifest, "manifest_digest"))
    )
    |> Base.encode16(case: :lower)
  end

  defp sha256_bytes(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp ancestors(path) do
    path
    |> Path.dirname()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.take_while(&(&1 not in [".", ""]))
  end

  defp target_manifest?(:web, "rekindle-web-manifest-v1.json"), do: true
  defp target_manifest?(:desktop, "rekindle-native-manifest-v1.json"), do: true
  defp target_manifest?(_target, _path), do: false

  defp safe_root?(value) when is_binary(value),
    do:
      Path.type(value) == :absolute and Path.basename(value) == ".rekindle" and
        (not File.exists?(value) or File.dir?(value))

  defp safe_root?(_value), do: false

  defp safe_profile?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
        not String.contains?(value, [<<0>>, "\n", "\r"])

  defp id?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{32}\z/, value)
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp uint?(value), do: is_integer(value) and value >= 0 and value <= @safe_integer

  defp target("web"), do: {:ok, :web}
  defp target("desktop"), do: {:ok, :desktop}
  defp target(_value), do: :error
  defp target_atom("web"), do: :web
  defp target_atom("desktop"), do: :desktop
  defp target_atom(_value), do: nil

  defp member_mode("regular"), do: {:ok, :regular}
  defp member_mode("executable_owner"), do: {:ok, :executable_owner}
  defp member_mode(_value), do: :error

  defp valid_marker?(marker, attempt_id) do
    is_map(marker) and
      Map.keys(marker) |> Enum.sort() ==
        ~w[attempt_id generation_id owner session_id target v] |> Enum.sort() and marker["v"] == 1 and
      marker["attempt_id"] == attempt_id and id?(marker["generation_id"]) and
      id?(marker["session_id"]) and marker["target"] in ["web", "desktop"] and
      is_binary(marker["owner"])
  end

  defp valid_pointer?(record, target) do
    is_map(record) and
      Map.keys(record) |> Enum.sort() ==
        ~w[artifact_id generation_id manifest_digest source_revision target v] |> Enum.sort() and
      record["v"] == 1 and record["target"] == Atom.to_string(target) and
      id?(record["generation_id"]) and digest?(record["artifact_id"]) and
      digest?(record["manifest_digest"]) and uint?(record["source_revision"])
  end

  defp reference_matches?(record, generation) do
    case generation_from_reference(record) do
      {:ok, existing} -> existing == generation
      _ -> false
    end
  end

  defp normalize_io({:error, %Failure{}} = error), do: error

  defp normalize_io({:error, _reason}),
    do: {:error, invalid(:execution, :io_failed, "Artifact I/O failed")}

  defp invalid_record,
    do: {:error, invalid(:artifact, :cache_corrupt, "Artifact store record is invalid")}

  defp lease_access_denied,
    do: invalid(:internal, :contract_violation, "Artifact lease access is not authorized")

  defp invalid(stage, code, message),
    do: Failure.new!(target: nil, stage: stage, code: code, message: message)
end
