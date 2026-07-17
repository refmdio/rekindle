defmodule Rekindle.ArtifactStore do
  @moduledoc false

  use GenServer

  import Bitwise

  alias Rekindle.ArtifactStore.{Descriptor, Filesystem, Lease, Member, Staging}
  alias Rekindle.{CanonicalValue, Failure, GenerationRef}

  @manifest_limit 67_108_864
  @member_limit 100_000
  @safe_integer 9_007_199_254_740_991

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
  def activate(server, generation, source_revision),
    do: GenServer.call(server, {:activate, generation, source_revision}, :infinity)

  @spec current(GenServer.server(), Rekindle.target()) :: {:ok, GenerationRef.t()} | :none
  def current(server, target), do: GenServer.call(server, {:current, target}, :infinity)

  @spec fallback(GenServer.server(), Rekindle.target()) :: {:ok, GenerationRef.t()} | :none
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
         :ok <- initialize_layout(root),
         {:ok, quarantined?} <- recover(root) do
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
    end
  end

  def handle_call({:activate, generation, revision}, _from, state) do
    with :ok <- writable(state),
         true <- uint?(revision),
         {:ok, generation} <- validate_generation(state, generation),
         :ok <- generation_source_revision(state, generation, revision),
         previous <- read_pointer(state, :current, generation.target),
         :ok <- write_pointer(state, :current, generation, revision),
         :ok <- write_fallback(state, previous) do
      {:reply, :ok, state}
    else
      false ->
        {:reply, {:error, invalid(:configuration, :config_invalid, "Revision is invalid")}, state}

      {:error, %Failure{} = failure} ->
        {:reply, {:error, failure}, state}
    end
  end

  def handle_call({:current, target}, _from, state) do
    {:reply, pointer_generation(state, :current, target), state}
  end

  def handle_call({:fallback, target}, _from, state) do
    {:reply, pointer_generation(state, :fallback, target), state}
  end

  def handle_call({:acquire, generation, source_revision}, {owner, _tag}, state) do
    with true <- source_revision == :any or uint?(source_revision),
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
    case Map.get(state.leases, token) do
      %{owner: ^owner, lease: ^lease} = entry ->
        authority = make_ref()
        release = {:rekindle_artifact_release, self(), token, authority}
        entry = %{entry | release_authorities: MapSet.put(entry.release_authorities, authority)}
        {:reply, {:ok, release}, put_in(state.leases[token], entry)}

      _ ->
        {:reply, {:error, release_denied()}, state}
    end
  end

  def handle_call({:release, %Lease{token: token} = lease}, {owner, _tag}, state) do
    case Map.get(state.leases, token) do
      %{owner: ^owner, lease: ^lease} -> {:reply, :ok, drop_lease(state, token)}
      _ -> {:reply, {:error, release_denied()}, state}
    end
  end

  def handle_call({:release_authority, token, authority}, _from, state) do
    case Map.get(state.leases, token) do
      %{release_authorities: authorities} ->
        if MapSet.member?(authorities, authority) do
          {:reply, :ok, drop_lease(state, token)}
        else
          {:reply, {:error, release_denied()}, state}
        end

      _ ->
        {:reply, {:error, release_denied()}, state}
    end
  end

  def handle_call({:revoke_release_authority, token, authority}, _from, state) do
    case Map.get(state.leases, token) do
      %{release_authorities: authorities} = entry ->
        if MapSet.member?(authorities, authority) do
          entry = %{entry | release_authorities: MapSet.delete(authorities, authority)}
          {:reply, :ok, put_in(state.leases[token], entry)}
        else
          {:reply, {:error, release_denied()}, state}
        end

      _ ->
        {:reply, {:error, release_denied()}, state}
    end
  end

  def handle_call({:valid_lease, %Lease{} = lease}, {owner, _tag}, state) do
    valid? =
      match?(
        %{owner: ^owner, lease: ^lease},
        Map.get(state.leases, lease.token)
      )

    {:reply, valid?, state}
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
    with :ok <- Filesystem.ensure_private_directory(root),
         :ok <- ensure_project_id(root),
         :ok <- ensure_directories(root) do
      :ok
    end
  end

  defp ensure_project_id(root) do
    path = Path.join(root, "project-id")

    case File.read(path) do
      {:ok, value} ->
        if id?(value),
          do: qualify_private_file(path),
          else: {:error, invalid(:configuration, :path_invalid, "Project identity is invalid")}

      {:error, :enoent} ->
        Filesystem.atomic_write(path, Filesystem.random_id())

      {:error, _reason} ->
        {:error, invalid(:execution, :io_failed, "Project identity could not be read")}
    end
  end

  defp ensure_directories(root) do
    directories =
      ["staging", "current", "fallback", "seals", "deletions"] ++
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
                   Filesystem.atomic_write(Path.join(attempt_path, "attempt-v1.json"), marker),
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
         :ok <- Filesystem.atomic_write(journal_path, seal_record(staging, descriptor)),
         :ok <- checkpoint(options, :journaled),
         :ok <- seal_tree(staging.path, descriptor),
         :ok <- checkpoint(options, :sealed),
         :ok <- publish_artifact(staging.path, final_path, staging.target, descriptor, options),
         :ok <- checkpoint(options, :renamed),
         :ok <- write_seal_metadata(state, staging.target, descriptor),
         :ok <- checkpoint(options, :metadata_published),
         {:ok, generation} <- write_reference(state, staging, descriptor),
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

  defp write_seal_metadata(state, target, descriptor) do
    path = seal_path(state, target, descriptor.artifact_id)

    case read_canonical(path) do
      {:ok, existing} ->
        if existing == descriptor_record(target, descriptor),
          do: :ok,
          else: {:error, invalid(:artifact, :artifact_changed, "Seal metadata changed")}

      :none ->
        Filesystem.atomic_write(path, descriptor_record(target, descriptor))

      {:error, _} = error ->
        error
    end
  end

  defp write_reference(state, staging, descriptor) do
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
        case Filesystem.atomic_write(path, record) do
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

  defp write_pointer(state, kind, generation, revision) do
    record = %{
      "v" => 1,
      "target" => Atom.to_string(generation.target),
      "generation_id" => generation.generation_id,
      "artifact_id" => generation.artifact_id,
      "manifest_digest" => generation.manifest_digest,
      "source_revision" => revision
    }

    Filesystem.atomic_write(pointer_path(state, kind, generation.target), record)
  end

  defp write_fallback(_state, :none), do: :ok

  defp write_fallback(state, {:ok, record}) do
    Filesystem.atomic_write(pointer_path(state, :fallback, target_atom(record["target"])), record)
  end

  defp write_fallback(_state, {:error, %Failure{} = failure}), do: {:error, failure}

  defp pointer_generation(state, kind, target) when target in [:web, :desktop] do
    case read_pointer(state, kind, target) do
      {:ok, record} ->
        with {:ok, reference} <- reference_from_record(state, record),
             {:ok, generation} <- validate_generation(state, reference) do
          {:ok, generation}
        else
          _ -> :none
        end

      _ ->
        :none
    end
  end

  defp pointer_generation(_state, _kind, _target), do: :none

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
    with {:ok, references} <- all_references(state) do
      protected =
        protected
        |> protect_pointer(state, :current)
        |> protect_pointer(state, :fallback)
        |> protect_leases(state)

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

    with :ok <- Filesystem.atomic_write(journal_path, journal),
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
    Enum.reduce([:web, :desktop], protected, fn target, acc ->
      case read_pointer(state, kind, target) do
        {:ok, record} -> MapSet.put(acc, record["generation_id"])
        _ -> acc
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
    quarantine = Path.join(root, "quarantine-v1.json")

    if File.exists?(quarantine) do
      {:ok, true}
    else
      case recover_staging(root) do
        :ok ->
          case recover_deletions(root) do
            :ok -> validate_persisted_state(root)
            {:error, %Failure{} = failure} -> quarantine(root, failure.message)
          end

        {:error, %Failure{} = failure} ->
          quarantine(root, failure.message)
      end
    end
  end

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
      :none -> Filesystem.atomic_write(path, record)
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
        Filesystem.atomic_write(path, record)

      {:error, _} = error ->
        error
    end
  end

  defp validate_persisted_state(root) do
    temporary = %__MODULE__{root: root}

    with :ok <- validate_control_directories(temporary),
         :ok <- validate_reference_directories(temporary),
         :ok <- validate_generation_directories(temporary),
         :ok <- validate_pointers(temporary) do
      {:ok, false}
    else
      {:error, %Failure{} = failure} -> quarantine(root, failure.message)
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
         false <- pointer_references?(state, record["generation_id"]),
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
    Enum.any?([:current, :fallback], fn kind ->
      Enum.any?([:web, :desktop], fn target ->
        case read_pointer(state, kind, target) do
          {:ok, record} -> record["generation_id"] == generation_id
          _ -> false
        end
      end)
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
        case read_pointer(state, kind, target) do
          :none ->
            {:cont, :ok}

          {:ok, record} ->
            case reference_from_record(state, record) do
              {:ok, _generation} -> {:cont, :ok}
              {:error, _} = error -> {:halt, error}
            end

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

    case Filesystem.atomic_write(Path.join(root, "quarantine-v1.json"), record) do
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
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) <= @manifest_limit ->
        with {:ok, value} <- Jason.decode(bytes),
             true <- is_map(value),
             true <- CanonicalValue.encode!(value) == bytes do
          {:ok, value}
        else
          _ -> invalid_record()
        end

      {:ok, _bytes} ->
        invalid_record()

      {:error, :enoent} ->
        :none

      {:error, _reason} ->
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

  defp writable(%{quarantined?: true}),
    do:
      {:error,
       invalid(:execution, :cleanup_unconfirmed, "Artifact store requires explicit cleanup")}

  defp writable(_state), do: :ok

  defp artifact_path(state, target, artifact_id),
    do: Path.join([state.root, "generations", Atom.to_string(target), artifact_id])

  defp reference_path(state, target, generation_id),
    do: Path.join([state.root, "references", Atom.to_string(target), generation_id <> ".json"])

  defp seal_path(state, target, artifact_id),
    do: Path.join([state.root, "seals", Atom.to_string(target), artifact_id <> ".json"])

  defp pointer_path(state, kind, target),
    do: Path.join([state.root, Atom.to_string(kind), Atom.to_string(target) <> ".json"])

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

  defp safe_path?(value) when is_binary(value) do
    segments = Path.split(value)

    value != "" and byte_size(value) <= 4_096 and String.valid?(value) and
      String.normalize(value, :nfc) == value and Path.type(value) == :relative and
      not String.contains?(value, ["\\", <<0>>]) and
      Enum.all?(segments, &(&1 not in ["", ".", ".."]))
  end

  defp safe_path?(_value), do: false

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

  defp release_denied,
    do: invalid(:internal, :contract_violation, "Artifact lease release is not authorized")

  defp invalid(stage, code, message),
    do: Failure.new!(target: nil, stage: stage, code: code, message: message)
end
