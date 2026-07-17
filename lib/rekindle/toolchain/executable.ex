defmodule Rekindle.Toolchain.Executable do
  @moduledoc false

  @enforce_keys [:path, :identity, :sha256, :size, :mode]
  defstruct @enforce_keys

  @max_bytes 1_073_741_824
  @identity_fields [:inode, :uid, :gid, :major_device, :minor_device, :size, :type, :mode]
  @launch_root_prefix ".rekindle-launch-"
  @termination_grace_ms 100
  @termination_kill_wait_ms 500

  @type t :: %__MODULE__{
          path: Path.t(),
          identity: map(),
          sha256: String.t(),
          size: non_neg_integer(),
          mode: non_neg_integer()
        }

  @spec qualify(Path.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def qualify(path, options \\ []) do
    maximum = Keyword.get(options, :max_bytes, @max_bytes)
    executable? = Keyword.get(options, :executable, true)
    required_mode = Keyword.get(options, :required_mode)

    with :ok <- absolute_canonical(path),
         {:ok, before_stat} <- no_follow_stat(path),
         :ok <- regular_file(before_stat, maximum),
         :ok <- coherent_owner(path, before_stat),
         :ok <- secure_mode(before_stat, executable?, required_mode),
         {:ok, digest, opened_stat} <- digest_handle(path, before_stat, maximum),
         :ok <- expected(digest, opened_stat, options) do
      {:ok,
       %__MODULE__{
         path: path,
         identity: identity(opened_stat),
         sha256: digest,
         size: opened_stat.size,
         mode: Bitwise.band(opened_stat.mode, 0o777)
       }}
    else
      _ -> {:error, :executable_unqualified}
    end
  rescue
    _ -> {:error, :executable_unqualified}
  catch
    _, _ -> {:error, :executable_unqualified}
  end

  @doc false
  @spec stat(Path.t()) :: {:ok, File.Stat.t()} | {:error, atom()}
  def stat(path) do
    with :ok <- absolute_canonical(path), do: no_follow_stat(path)
  end

  @doc false
  @spec first_unsafe_component(Path.t()) :: {:ok, Path.t()} | {:error, atom()}
  def first_unsafe_component(path) do
    with :ok <- absolute_canonical(path),
         [_ | _] = components <- Path.split(path) do
      find_unsafe_component("", components)
    end
  end

  @spec revalidate(t()) :: :ok | {:error, atom()}
  def revalidate(%__MODULE__{} = admitted) do
    with {:ok, current} <-
           qualify(admitted.path,
             expected_sha256: admitted.sha256,
             expected_size: admitted.size,
             required_mode: admitted.mode
           ),
         true <- same_authority?(admitted, current) do
      :ok
    else
      _ -> {:error, :executable_changed}
    end
  end

  @spec open(t(), [String.t()], keyword()) ::
          {:ok, port(), tuple()} | {:error, atom()}
  def open(%__MODULE__{} = admitted, argv, options \\ []) do
    with :ok <- argv(argv),
         :ok <- invoke_hook(options, :before_spawn, admitted),
         :ok <- revalidate(admitted),
         {:ok, handle, launch_path, launch_authority} <- launch_handle(admitted) do
      case spawn_handle(admitted, launch_path, argv, options) do
        {:ok, port} ->
          case {invoke_hook(options, :after_spawn, admitted),
                admit_launch_handle(handle, launch_authority)} do
            {:ok, :ok} ->
              {:ok, port, handle}

            _error ->
              terminate(port)
              release(handle)
              {:error, :executable_changed}
          end

        _error ->
          release(handle)
          {:error, :executable_changed}
      end
    else
      _ -> {:error, :executable_changed}
    end
  rescue
    _ -> {:error, :executable_changed}
  catch
    _, _ -> {:error, :executable_changed}
  end

  @spec run(t(), [String.t()], keyword()) ::
          {:ok, {binary(), non_neg_integer()}} | {:error, atom()}
  def run(%__MODULE__{} = admitted, argv, options \\ []) do
    with {:ok, port, handle} <- open(admitted, argv, options) do
      try do
        result =
          collect(
            port,
            <<>>,
            0,
            Keyword.get(options, :max_output_bytes, 4_194_304),
            monotonic_ms() + Keyword.get(options, :timeout_ms, 900_000)
          )

        case {result, revalidate(admitted)} do
          {{:ok, _command} = result, :ok} -> result
          {{:error, _reason} = error, _revalidation} -> error
          {_result, {:error, _reason}} -> {:error, :executable_changed}
        end
      after
        release(handle)
      end
    end
  end

  @doc false
  @spec release(tuple() | :file.io_device()) :: :ok
  def release({:launch_handle, handle, root, root_identity}) do
    release(handle)
    remove_launch_root(root, root_identity)
  end

  def release(handle) do
    :file.close(handle)
    :ok
  rescue
    _ -> :ok
  end

  @spec ensure_private_directory(Path.t()) :: :ok | {:error, atom()}
  def ensure_private_directory(path) do
    with :ok <- absolute_canonical(path),
         [_ | _] = components <- Path.split(path),
         {:ok, stat} <- ensure_directory_components("", components),
         true <- stat.type == :directory,
         :ok <- File.chmod(path, 0o700),
         {:ok, final_stat} <- no_follow_stat(path),
         true <- same_identity_except_mode?(stat, final_stat),
         true <- Bitwise.band(final_stat.mode, 0o777) == 0o700 do
      :ok
    else
      _ -> {:error, :directory_unqualified}
    end
  rescue
    _ -> {:error, :directory_unqualified}
  end

  defp spawn_handle(admitted, launch_path, argv, options) do
    spawn = fn -> open_port(launch_path, admitted.path, argv, options) end

    case Keyword.get(options, :around_spawn) do
      nil -> spawn.()
      hook when is_function(hook, 3) -> hook.(admitted, launch_path, spawn)
      _ -> {:error, :invalid_hook}
    end
  rescue
    _ -> {:error, :executable_changed}
  catch
    _, _ -> {:error, :executable_changed}
  end

  defp open_port(path, arg0, argv, options) do
    port_options = [
      :binary,
      :exit_status,
      :use_stdio,
      arg0: String.to_charlist(arg0),
      args: Enum.map(argv, &String.to_charlist/1)
    ]

    port_options =
      if Keyword.get(options, :stderr_to_stdout, true),
        do: [:stderr_to_stdout | port_options],
        else: port_options

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(path)},
        port_options
      )

    {:ok, port}
  end

  defp launch_handle(admitted) do
    case :file.open(admitted.path, [:read, :binary, :raw]) do
      {:ok, source} ->
        try do
          with :ok <- admit_source_handle(source, admitted),
               {:ok, handle, launch_authority} <- sealed_copy(source, admitted),
               {:ok, launch} <- prepare_launch_reference(handle, launch_authority) do
            {:ok, launch.handle, launch.path, launch.authority}
          else
            _ -> {:error, :executable_changed}
          end
        after
          release(source)
        end

      _ ->
        {:error, :executable_changed}
    end
  end

  defp prepare_launch_reference(handle, launch_authority) do
    with {:ok, launch_path} <- launch_path(handle),
         {:ok, launch_stat} <- File.stat(launch_path),
         true <- identity(launch_stat) == launch_authority.identity do
      {:ok, %{handle: handle, path: launch_path, authority: launch_authority}}
    else
      _ ->
        release(handle)
        {:error, :executable_changed}
    end
  end

  defp admit_source_handle(handle, admitted) do
    with {:ok, opened_record} <- :file.read_file_info(handle),
         opened_stat = File.Stat.from_record(opened_record),
         true <- identity(opened_stat) == admitted.identity,
         {:ok, context, size} <-
           hash_handle(handle, :crypto.hash_init(:sha256), 0, admitted.size),
         true <- size == admitted.size,
         digest = :crypto.hash_final(context) |> Base.encode16(case: :lower),
         true <- digest == admitted.sha256,
         {:ok, _position} <- :file.position(handle, 0) do
      :ok
    else
      _ -> {:error, :executable_changed}
    end
  end

  defp sealed_copy(source, admitted) do
    with {:ok, root, root_identity} <- create_launch_root() do
      result =
        try do
          sealed_copy(source, admitted, root)
        rescue
          _ -> {:error, :executable_changed}
        catch
          _, _ -> {:error, :executable_changed}
        end

      case result do
        {:ok, handle, launch_authority} ->
          {:ok, {:launch_handle, handle, root, root_identity}, launch_authority}

        {:error, _reason} = error ->
          remove_launch_root(root, root_identity)
          error
      end
    end
  end

  defp sealed_copy(source, admitted, root) do
    name = "exec-#{System.unique_integer([:positive, :monotonic])}"
    path = Path.join(root, name)

    try do
      case :file.open(path, [:write, :binary, :raw, :exclusive]) do
        {:ok, destination} ->
          case launch_entry_identity(destination, path) do
            {:ok, entry_identity} ->
              try do
                with {:ok, entry_record} <- :file.read_file_info(destination),
                     true <- node_identity(File.Stat.from_record(entry_record)) == entry_identity,
                     :ok <- copy_handle(source, destination, admitted.size),
                     :ok <- :file.sync(destination),
                     :ok <- release(destination),
                     :ok <- File.chmod(path, 0o500) do
                  open_unlinked_seal(path, admitted)
                else
                  _ -> {:error, :executable_changed}
                end
              after
                release(destination)
                remove_launch_entry(path, entry_identity)
              end

            _error ->
              release(destination)
              remove_unidentified_launch_entry(path)
              {:error, :executable_changed}
          end

        _error ->
          {:error, :executable_changed}
      end
    rescue
      _error ->
        remove_unidentified_launch_entry(path)
        {:error, :executable_changed}
    catch
      _, _ ->
        remove_unidentified_launch_entry(path)
        {:error, :executable_changed}
    end
  end

  defp remove_unidentified_launch_entry(_path), do: :ok

  defp launch_entry_identity(destination, path) do
    case :file.read_file_info(destination) do
      {:ok, record} -> {:ok, record |> File.Stat.from_record() |> node_identity()}
      _ -> launch_entry_path_identity(path)
    end
  rescue
    _ -> launch_entry_path_identity(path)
  catch
    _, _ -> launch_entry_path_identity(path)
  end

  defp launch_entry_path_identity(path) do
    case File.lstat(path) do
      {:ok, stat} -> {:ok, node_identity(stat)}
      _ -> {:error, :executable_changed}
    end
  rescue
    _ -> {:error, :executable_changed}
  end

  defp open_unlinked_seal(path, admitted) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, handle} ->
        case File.rm(path) do
          :ok ->
            case seal_authority(handle, admitted) do
              {:ok, launch_authority} ->
                {:ok, handle, launch_authority}

              {:error, _} = error ->
                release(handle)
                error
            end

          _error ->
            release(handle)
            {:error, :executable_changed}
        end

      _error ->
        File.rm(path)
        {:error, :executable_changed}
    end
  end

  defp seal_authority(handle, admitted) do
    with {:ok, opened_record} <- :file.read_file_info(handle),
         opened_stat = File.Stat.from_record(opened_record),
         true <- opened_stat.type == :regular,
         true <- opened_stat.size == admitted.size,
         true <- Bitwise.band(opened_stat.mode, 0o777) == 0o500,
         {:ok, context, size} <-
           hash_handle(handle, :crypto.hash_init(:sha256), 0, admitted.size),
         true <- size == admitted.size,
         digest = :crypto.hash_final(context) |> Base.encode16(case: :lower),
         true <- digest == admitted.sha256,
         {:ok, _position} <- :file.position(handle, 0) do
      {:ok, %{identity: identity(opened_stat), sha256: digest, size: size, mode: 0o500}}
    else
      _ -> {:error, :executable_changed}
    end
  end

  defp admit_launch_handle(handle, launch_authority) do
    io = launch_io(handle)

    with {:ok, opened_record} <- :file.read_file_info(io),
         opened_stat = File.Stat.from_record(opened_record),
         true <- identity(opened_stat) == launch_authority.identity,
         true <- Bitwise.band(opened_stat.mode, 0o777) == launch_authority.mode,
         {:ok, context, size} <-
           hash_handle(io, :crypto.hash_init(:sha256), 0, launch_authority.size),
         true <- size == launch_authority.size,
         digest = :crypto.hash_final(context) |> Base.encode16(case: :lower),
         true <- digest == launch_authority.sha256,
         {:ok, _position} <- :file.position(io, 0) do
      :ok
    else
      _ -> {:error, :executable_changed}
    end
  end

  defp copy_handle(source, destination, expected_size) do
    with {:ok, _position} <- :file.position(source, 0) do
      copy_handle(source, destination, 0, expected_size)
    end
  end

  defp copy_handle(source, destination, copied, expected_size) do
    case :file.read(source, 64 * 1_024) do
      {:ok, bytes} when copied + byte_size(bytes) <= expected_size ->
        with :ok <- :file.write(destination, bytes) do
          copy_handle(source, destination, copied + byte_size(bytes), expected_size)
        end

      :eof when copied == expected_size ->
        :ok

      _ ->
        {:error, :executable_changed}
    end
  end

  defp launch_path(handle) do
    with raw when is_binary(raw) <- :prim_file.get_handle(launch_io(handle)),
         true <- byte_size(raw) in [4, 8],
         descriptor <- :binary.decode_unsigned(raw, :little),
         true <- descriptor >= 0 do
      case :os.type() do
        {:unix, :linux} -> {:ok, "/proc/#{System.pid()}/fd/#{descriptor}"}
        {:unix, :darwin} -> {:ok, "/dev/fd/#{descriptor}"}
        _ -> {:error, :unsupported_host}
      end
    else
      _ -> {:error, :executable_changed}
    end
  end

  defp launch_io({:launch_handle, handle, _root, _identity}), do: handle

  defp create_launch_root(attempts \\ 16)

  defp create_launch_root(attempts) when attempts > 0 do
    suffix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    root = Path.join(System.tmp_dir!(), @launch_root_prefix <> suffix)

    case File.mkdir(root) do
      :ok ->
        with :ok <- File.chmod(root, 0o700),
             {:ok, stat} <- File.lstat(root),
             true <- stat.type == :directory,
             true <- Bitwise.band(stat.mode, 0o777) == 0o700 do
          {:ok, root, directory_identity(stat)}
        else
          _ ->
            File.rmdir(root)
            {:error, :executable_changed}
        end

      {:error, :eexist} ->
        create_launch_root(attempts - 1)

      _ ->
        {:error, :executable_changed}
    end
  end

  defp create_launch_root(0), do: {:error, :executable_changed}

  defp remove_launch_root(root, expected_identity) do
    with {:ok, stat} <- File.lstat(root),
         true <- directory_identity(stat) == expected_identity,
         {:ok, []} <- File.ls(root),
         :ok <- File.rmdir(root) do
      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp remove_launch_entry(path, expected_identity) do
    with {:ok, stat} <- File.lstat(path),
         true <- node_identity(stat) == expected_identity do
      File.rm(path)
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp directory_identity(stat) do
    fields = [:inode, :uid, :gid, :major_device, :minor_device, :type, :mode]
    Map.take(stat, fields)
  end

  defp node_identity(stat) do
    fields = [:inode, :uid, :gid, :major_device, :minor_device, :type]
    Map.take(stat, fields)
  end

  defp collect(port, output, discarded, maximum, deadline) do
    receive do
      {^port, {:data, bytes}} ->
        remaining = max(maximum - byte_size(output), 0)
        kept = min(byte_size(bytes), remaining)
        output = if kept == 0, do: output, else: output <> binary_part(bytes, 0, kept)
        collect(port, output, discarded + byte_size(bytes) - kept, maximum, deadline)

      {^port, {:exit_status, status}} ->
        {:ok, {output, status}}

      {^port, :closed} ->
        collect(port, output, discarded, maximum, deadline)
    after
      max(deadline - monotonic_ms(), 0) ->
        terminate(port)
        {:error, :executable_timeout}
    end
  end

  defp digest_handle(path, before_stat, maximum) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, handle} ->
        try do
          with {:ok, opened_record} <- :file.read_file_info(handle),
               opened_stat = File.Stat.from_record(opened_record),
               true <- same_identity?(before_stat, opened_stat),
               {:ok, context, size} <- hash_handle(handle, :crypto.hash_init(:sha256), 0, maximum),
               true <- size == opened_stat.size,
               {:ok, final_record} <- :file.read_file_info(handle),
               final_stat = File.Stat.from_record(final_record),
               true <- same_identity?(opened_stat, final_stat),
               {:ok, after_stat} <- no_follow_stat(path),
               true <- same_identity?(opened_stat, after_stat) do
            {:ok, :crypto.hash_final(context) |> Base.encode16(case: :lower), opened_stat}
          else
            _ -> {:error, :executable_changed}
          end
        after
          :file.close(handle)
        end

      _ ->
        {:error, :executable_unqualified}
    end
  end

  defp hash_handle(handle, context, size, maximum) do
    case :file.read(handle, 64 * 1_024) do
      {:ok, bytes} when byte_size(bytes) > 0 and size + byte_size(bytes) <= maximum ->
        hash_handle(handle, :crypto.hash_update(context, bytes), size + byte_size(bytes), maximum)

      :eof ->
        {:ok, context, size}

      _ ->
        {:error, :executable_unqualified}
    end
  end

  defp expected(digest, stat, options) do
    expected_digest = Keyword.get(options, :expected_sha256)
    expected_size = Keyword.get(options, :expected_size)

    if (is_nil(expected_digest) or expected_digest == digest) and
         (is_nil(expected_size) or expected_size == stat.size),
       do: :ok,
       else: {:error, :executable_changed}
  end

  defp regular_file(stat, maximum) do
    if stat.type == :regular and stat.size in 1..maximum,
      do: :ok,
      else: {:error, :executable_unqualified}
  end

  defp coherent_owner(path, stat) do
    with {:ok, parent} <- no_follow_stat(Path.dirname(path)),
         true <- parent.type == :directory,
         true <- stat.uid == parent.uid do
      :ok
    else
      _ -> {:error, :executable_unqualified}
    end
  end

  defp secure_mode(stat, executable?, required_mode) do
    mode = Bitwise.band(stat.mode, 0o777)

    cond do
      is_integer(required_mode) and mode != required_mode -> {:error, :executable_unqualified}
      executable? and Bitwise.band(mode, 0o111) == 0 -> {:error, :executable_unqualified}
      Bitwise.band(mode, 0o022) != 0 -> {:error, :executable_unqualified}
      true -> :ok
    end
  end

  defp absolute_canonical(path) when is_binary(path) do
    if Path.type(path) == :absolute and Path.expand(path) == path,
      do: :ok,
      else: {:error, :invalid_path}
  end

  defp absolute_canonical(_path), do: {:error, :invalid_path}

  defp no_follow_stat(path) do
    with [_ | _] = components <- Path.split(path) do
      no_follow_components("", components)
    end
  end

  defp no_follow_components(current, [component | rest]) do
    path = if current == "", do: component, else: Path.join(current, component)

    with {:ok, stat} <- File.lstat(path),
         true <- stat.type != :symlink,
         true <- rest == [] or stat.type == :directory do
      if rest == [], do: {:ok, stat}, else: no_follow_components(path, rest)
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_path}
    end
  end

  defp find_unsafe_component(current, [component | rest]) do
    path = if current == "", do: component, else: Path.join(current, component)

    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        {:ok, path}

      {:ok, %{type: :directory}} when rest != [] ->
        find_unsafe_component(path, rest)

      {:ok, _stat} when rest != [] ->
        {:ok, path}

      {:ok, _stat} ->
        {:error, :none}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_directory_components(current, [component | rest]) do
    path = if current == "", do: component, else: Path.join(current, component)

    stat =
      case File.lstat(path) do
        {:ok, stat} ->
          {:ok, stat}

        {:error, :enoent} ->
          case File.mkdir(path) do
            :ok ->
              with :ok <- File.chmod(path, 0o700),
                   {:ok, stat} <- File.lstat(path) do
                {:ok, stat}
              end

            {:error, :eexist} ->
              File.lstat(path)

            _ ->
              {:error, :invalid_path}
          end

        _ ->
          {:error, :invalid_path}
      end

    with {:ok, stat} <- stat,
         true <- stat.type == :directory do
      if rest == [], do: {:ok, stat}, else: ensure_directory_components(path, rest)
    else
      _ -> {:error, :invalid_path}
    end
  end

  defp identity(stat), do: Map.take(stat, @identity_fields)
  defp same_identity?(left, right), do: identity(left) == identity(right)

  defp same_identity_except_mode?(left, right) do
    fields = @identity_fields -- [:mode, :size]
    Map.take(left, fields) == Map.take(right, fields)
  end

  defp same_authority?(left, right) do
    left.path == right.path and left.identity == right.identity and left.sha256 == right.sha256 and
      left.size == right.size and left.mode == right.mode
  end

  defp argv(values) when is_list(values) do
    if Enum.all?(
         values,
         &(is_binary(&1) and String.valid?(&1) and not String.contains?(&1, <<0>>))
       ),
       do: :ok,
       else: {:error, :invalid_argv}
  end

  defp argv(_values), do: {:error, :invalid_argv}

  defp invoke_hook(options, key, admitted) do
    case Keyword.get(options, key) do
      nil -> :ok
      hook when is_function(hook, 0) -> hook.()
      hook when is_function(hook, 1) -> hook.(admitted)
      _ -> {:error, :invalid_hook}
    end
  rescue
    _ -> {:error, :hook_failed}
  catch
    _, _ -> {:error, :hook_failed}
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp terminate(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> terminate_process_tree(pid)
      _ -> :ok
    end

    close(port)
  rescue
    _ -> close(port)
  catch
    _, _ -> close(port)
  end

  defp terminate_process_tree(root_pid) do
    records = process_tree(root_pid)
    signal_records(records, "TERM")
    wait_for_processes(records, monotonic_ms() + @termination_grace_ms)

    survivors = surviving_records(records)
    signal_records(survivors, "KILL")
    wait_for_processes(survivors, monotonic_ms() + @termination_kill_wait_ms)
    :ok
  end

  defp process_tree(root_pid) do
    records = process_records()
    by_pid = Map.new(records, &{&1.pid, &1})
    children = Enum.group_by(records, & &1.ppid)
    collect_process_tree([{root_pid, 0}], by_pid, children, MapSet.new(), [])
  end

  defp collect_process_tree([], _by_pid, _children, _seen, records),
    do: Enum.sort_by(records, &{-&1.depth, &1.pid})

  defp collect_process_tree(
         [{pid, depth} | pending],
         by_pid,
         children,
         seen,
         records
       ) do
    if MapSet.member?(seen, pid) do
      collect_process_tree(pending, by_pid, children, seen, records)
    else
      seen = MapSet.put(seen, pid)
      descendants = Enum.map(Map.get(children, pid, []), &{&1.pid, depth + 1})

      records =
        case by_pid do
          %{^pid => record} -> [%{record | depth: depth} | records]
          %{} -> records
        end

      collect_process_tree(descendants ++ pending, by_pid, children, seen, records)
    end
  end

  defp signal_records([], _signal), do: :ok

  defp signal_records(records, signal) do
    current = Map.new(process_records(), &{&1.pid, &1})

    Enum.each(records, fn %{pid: pid} = record ->
      case current do
        %{^pid => %{identity: identity, state: state}}
        when identity == record.identity and state != "Z" ->
          signal_process(pid, signal)

        _ ->
          :ok
      end
    end)
  end

  defp wait_for_processes(records, deadline) do
    if surviving_records(records) == [] or monotonic_ms() >= deadline do
      :ok
    else
      Process.sleep(5)
      wait_for_processes(records, deadline)
    end
  end

  defp surviving_records(records) do
    current = Map.new(process_records(), &{&1.pid, &1})

    Enum.filter(records, fn %{pid: pid} = record ->
      case current do
        %{^pid => %{identity: identity, state: state}} ->
          identity == record.identity and state != "Z"

        _ ->
          false
      end
    end)
  end

  defp process_records do
    case :os.type() do
      {:unix, :linux} -> linux_process_records()
      {:unix, _name} -> ps_process_records()
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp linux_process_records do
    "/proc/[0-9]*/stat"
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      with {pid, ""} <- path |> Path.dirname() |> Path.basename() |> Integer.parse(),
           {:ok, bytes} <- File.read(path),
           [{offset, 2} | _] <- :binary.matches(bytes, ") ") |> Enum.reverse(),
           fields <-
             binary_part(bytes, offset + 2, byte_size(bytes) - offset - 2) |> String.split(),
           state when is_binary(state) <- Enum.at(fields, 0),
           ppid when is_binary(ppid) <- Enum.at(fields, 1),
           start_time when is_binary(start_time) <- Enum.at(fields, 19),
           {ppid, ""} <- Integer.parse(ppid) do
        [%{pid: pid, ppid: ppid, identity: {:linux, start_time}, state: state, depth: 0}]
      else
        _ -> []
      end
    end)
  end

  defp ps_process_records do
    with path when is_binary(path) <- system_executable(["/bin/ps", "/usr/bin/ps"]),
         {output, 0} <- System.cmd(path, ["-axo", "pid=,ppid=,state=,lstart="]) do
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, ~r/\s+/, parts: 4, trim: true) do
          [pid, ppid, state, started] ->
            with {pid, ""} <- Integer.parse(pid),
                 {ppid, ""} <- Integer.parse(ppid) do
              [%{pid: pid, ppid: ppid, identity: {:ps, started}, state: state, depth: 0}]
            else
              _ -> []
            end

          _ ->
            []
        end
      end)
    else
      _ -> []
    end
  end

  defp signal_process(pid, signal) do
    case system_executable(["/bin/kill", "/usr/bin/kill"]) do
      path when is_binary(path) ->
        System.cmd(path, ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
        :ok

      nil ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp system_executable(paths), do: Enum.find(paths, &File.regular?/1)

  defp close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end
end
