defmodule Rekindle.TargetBackend.CallbackCoordinator do
  @moduledoc false

  alias Rekindle.{Diagnostic, Failure}

  @max_heap_words 2_000_000
  @cleanup_timeout_ms 1_000
  @deadlines %{
    backend_id: 1_000,
    backend_version: 1_000,
    validate: 1_000,
    plan: 5_000,
    finalize: 5_000
  }
  @resource_calls [
    {:ets, :new, 2},
    {:erlang, :monitor, 2},
    {:erlang, :open_port, 2},
    {:erlang, :link, 1}
  ]

  @diagnostic_codes %{
    {:backend_id, :cleanup} => :backend_backend_id_cleanup,
    {:backend_id, :resource} => :backend_backend_id_resource,
    {:backend_id, :timeout} => :backend_backend_id_timeout,
    {:backend_id, :crash} => :backend_backend_id_crash,
    {:backend_id, :return} => :backend_backend_id_return,
    {:backend_version, :cleanup} => :backend_backend_version_cleanup,
    {:backend_version, :resource} => :backend_backend_version_resource,
    {:backend_version, :timeout} => :backend_backend_version_timeout,
    {:backend_version, :crash} => :backend_backend_version_crash,
    {:backend_version, :return} => :backend_backend_version_return,
    {:validate, :cleanup} => :backend_validate_cleanup,
    {:validate, :resource} => :backend_validate_resource,
    {:validate, :timeout} => :backend_validate_timeout,
    {:validate, :crash} => :backend_validate_crash,
    {:validate, :return} => :backend_validate_return,
    {:plan, :cleanup} => :backend_plan_cleanup,
    {:plan, :resource} => :backend_plan_resource,
    {:plan, :timeout} => :backend_plan_timeout,
    {:plan, :crash} => :backend_plan_crash,
    {:plan, :return} => :backend_plan_return,
    {:finalize, :cleanup} => :backend_finalize_cleanup,
    {:finalize, :resource} => :backend_finalize_resource,
    {:finalize, :timeout} => :backend_finalize_timeout,
    {:finalize, :crash} => :backend_finalize_crash,
    {:finalize, :return} => :backend_finalize_return
  }

  @type callback :: :backend_id | :backend_version | :validate | :plan | :finalize

  @spec invoke(module(), callback(), [term()], Rekindle.target() | nil) ::
          {:ok, term()} | {:error, Failure.t()}
  def invoke(module, callback, arguments, target)
      when is_atom(module) and is_map_key(@deadlines, callback) and is_list(arguments) and
             target in [nil, :web, :desktop] do
    enable_resource_call_tracing()
    owner = self()
    token = make_ref()

    options = [
      :monitor,
      {:max_heap_size,
       %{
         size: @max_heap_words,
         kill: true,
         error_logger: false,
         include_shared_binaries: true
       }}
    ]

    {pid, monitor} =
      :erlang.spawn_opt(fn -> callback_process(owner, token) end, options)

    1 = :erlang.trace(pid, true, [:call, :procs, :ports, :set_on_spawn, {:tracer, owner}])
    send(pid, {:invoke, token, module, callback, arguments})

    state = %{
      callback: callback,
      target: target,
      token: token,
      pid: pid,
      monitor: monitor,
      deadline: monotonic_ms() + Map.fetch!(@deadlines, callback),
      traced_pids: MapSet.new([pid]),
      traced_ports: MapSet.new(),
      resource_violation: false
    }

    await_outcome(state)
  end

  @doc false
  @spec invalid_return(callback(), Rekindle.target() | nil) :: {:error, Failure.t()}
  def invalid_return(callback, target) when is_map_key(@deadlines, callback) do
    failure(callback, target, :return)
  end

  defp callback_process(owner, token) do
    receive do
      {:invoke, ^token, module, callback, arguments} ->
        outcome =
          try do
            {:returned, apply(module, callback, arguments)}
          catch
            kind, reason -> {:crashed, kind, reason}
          end

        send(owner, {:backend_callback, token, self(), outcome})

        receive do
          {:finish, ^token} -> :ok
        end
    end
  end

  defp await_outcome(state) do
    case remaining(state.deadline) do
      0 ->
        terminate(state, :timeout)

      wait ->
        receive do
          {:backend_callback, token, pid, {:returned, value}}
          when token == state.token and pid == state.pid ->
            finish_return(state, value)

          {:backend_callback, token, pid, {:crashed, _kind, _reason}}
          when token == state.token and pid == state.pid ->
            terminate(state, :crash)

          {:DOWN, monitor, :process, pid, :killed}
          when monitor == state.monitor and pid == state.pid ->
            terminate(mark_resource(state), :resource)

          {:DOWN, monitor, :process, pid, _reason}
          when monitor == state.monitor and pid == state.pid ->
            terminate(state, :crash)

          {:trace, _source, _event, _detail} = message ->
            handle_outcome_trace(message, state)

          {:trace, _source, _event, _detail, _extra} = message ->
            handle_outcome_trace(message, state)
        after
          wait -> terminate(state, :timeout)
        end
    end
  end

  defp handle_outcome_trace(message, state) do
    case trace_resource(message, state) do
      {:resource, updated} -> terminate(updated, :resource)
      {:trace, updated} -> await_outcome(updated)
      :unrelated -> await_outcome(state)
    end
  end

  defp handle_exit_trace(message, state, barrier, value, down?, delivered?) do
    case trace_resource(message, state) do
      {:resource, updated} -> terminate(updated, :resource)
      {:trace, updated} -> await_normal_exit(updated, barrier, value, down?, delivered?)
      :unrelated -> await_normal_exit(state, barrier, value, down?, delivered?)
    end
  end

  defp finish_return(state, value) do
    case current_resources(state) do
      {:resource, updated} ->
        terminate(updated, :resource)

      {:ok, updated} ->
        barrier = :erlang.trace_delivered(updated.pid)
        await_normal_exit(updated, barrier, value, false, false)
    end
  catch
    :error, :badarg -> terminate(state, :crash)
  end

  defp await_normal_exit(state, barrier, value, down?, delivered?) do
    if down? and delivered? do
      disable_trace(state)
      {:ok, value}
    else
      case remaining(state.deadline) do
        0 ->
          terminate(state, :timeout)

        wait ->
          receive do
            {:DOWN, monitor, :process, pid, :normal}
            when monitor == state.monitor and pid == state.pid ->
              await_normal_exit(state, barrier, value, true, delivered?)

            {:DOWN, monitor, :process, pid, :killed}
            when monitor == state.monitor and pid == state.pid ->
              terminate(mark_resource(state), :resource)

            {:DOWN, monitor, :process, pid, _reason}
            when monitor == state.monitor and pid == state.pid ->
              terminate(state, :crash)

            {:trace_delivered, pid, ref} when pid == state.pid and ref == barrier ->
              disable_trace(state)
              send(state.pid, {:finish, state.token})
              await_normal_exit(state, barrier, value, down?, true)

            {:trace, _source, _event, _detail} = message ->
              handle_exit_trace(message, state, barrier, value, down?, delivered?)

            {:trace, _source, _event, _detail, _extra} = message ->
              handle_exit_trace(message, state, barrier, value, down?, delivered?)
          after
            wait -> terminate(state, :timeout)
          end
      end
    end
  end

  defp terminate(state, reason) do
    cleanup_deadline = monotonic_ms() + @cleanup_timeout_ms
    state = drain_trace_barrier(state, cleanup_deadline)
    reason = if state.resource_violation, do: :resource, else: reason

    monitored =
      state.traced_pids
      |> Enum.reject(&(&1 == self() or not Process.alive?(&1)))
      |> Enum.map(fn
        pid when pid == state.pid -> {pid, state.monitor}
        pid -> {pid, Process.monitor(pid)}
      end)

    disable_trace(state)
    Enum.each(monitored, fn {pid, _monitor} -> Process.exit(pid, :kill) end)
    Enum.each(state.traced_ports, &close_port/1)

    if await_cleanup(monitored, state.traced_ports, cleanup_deadline) do
      failure(state.callback, state.target, reason)
    else
      failure(state.callback, state.target, :cleanup)
    end
  end

  defp drain_trace_barrier(state, deadline) do
    barrier =
      try do
        :erlang.trace_delivered(state.pid)
      catch
        :error, :badarg -> nil
      end

    drain_trace_barrier(state, barrier, deadline)
  end

  defp drain_trace_barrier(state, nil, _deadline), do: collect_pending_traces(state)

  defp drain_trace_barrier(state, barrier, deadline) do
    case remaining(deadline) do
      0 ->
        state

      wait ->
        receive do
          {:trace_delivered, pid, ref} when pid == state.pid and ref == barrier ->
            collect_pending_traces(state)

          {:DOWN, monitor, :process, pid, :killed}
          when monitor == state.monitor and pid == state.pid ->
            drain_trace_barrier(mark_resource(state), barrier, deadline)

          {:trace, _source, _event, _detail} = message ->
            case trace_resource(message, state) do
              {:resource, updated} -> drain_trace_barrier(updated, barrier, deadline)
              {:trace, updated} -> drain_trace_barrier(updated, barrier, deadline)
            end

          {:trace, _source, _event, _detail, _extra} = message ->
            case trace_resource(message, state) do
              {:resource, updated} -> drain_trace_barrier(updated, barrier, deadline)
              {:trace, updated} -> drain_trace_barrier(updated, barrier, deadline)
            end
        after
          wait -> state
        end
    end
  end

  defp current_resources(state) do
    links = process_info_list(state.pid, :links)
    monitors = process_info_list(state.pid, :monitors)

    owned_tables =
      :ets.all()
      |> Enum.filter(fn table ->
        try do
          :ets.info(table, :owner) == state.pid
        catch
          :error, :badarg -> false
        end
      end)

    state =
      Enum.reduce(links, state, fn
        port, acc when is_port(port) -> %{acc | traced_ports: MapSet.put(acc.traced_ports, port)}
        pid, acc when is_pid(pid) -> %{acc | traced_pids: MapSet.put(acc.traced_pids, pid)}
        _other, acc -> acc
      end)

    if links != [] or monitors != [] or owned_tables != [] do
      {:resource, mark_resource(state)}
    else
      {:ok, state}
    end
  end

  defp trace_resource({:trace, source, :spawn, child, _mfa}, state)
       when is_pid(source) and is_pid(child) do
    {:resource, state |> remember_resource(child) |> mark_resource()}
  end

  defp trace_resource(
         {:trace, source, :call, {:erlang, :monitor, [:process, :code_server]}},
         state
       ) do
    {:trace, remember_resource(state, source)}
  end

  defp trace_resource({:trace, source, :call, {module, function, arguments}}, state)
       when {module, function, length(arguments)} in @resource_calls do
    {:resource, state |> remember_resource(source) |> mark_resource()}
  end

  defp trace_resource({:trace, source, event, other}, state)
       when event in [:link, :getting_linked] do
    state = remember_resource(state, source) |> remember_resource(other)
    {:resource, mark_resource(state)}
  end

  defp trace_resource({:trace, source, event, resource, _detail}, state)
       when event in [:open, :getting_linked] do
    state = remember_resource(state, source) |> remember_resource(resource)
    {:resource, mark_resource(state)}
  end

  defp trace_resource({:trace, source, :spawned, parent, _mfa}, state) do
    {:trace, state |> remember_resource(source) |> remember_resource(parent)}
  end

  defp trace_resource({:trace, source, _event, _detail}, state) do
    {:trace, remember_resource(state, source)}
  end

  defp trace_resource({:trace, source, _event, _detail, _extra}, state) do
    {:trace, remember_resource(state, source)}
  end

  defp trace_resource(_message, _state), do: :unrelated

  defp remember_resource(state, resource) when is_pid(resource),
    do: %{state | traced_pids: MapSet.put(state.traced_pids, resource)}

  defp remember_resource(state, resource) when is_port(resource),
    do: %{state | traced_ports: MapSet.put(state.traced_ports, resource)}

  defp remember_resource(state, _resource), do: state

  defp mark_resource(state), do: %{state | resource_violation: true}

  defp collect_pending_traces(state) do
    receive do
      {:DOWN, monitor, :process, pid, :killed}
      when monitor == state.monitor and pid == state.pid ->
        collect_pending_traces(mark_resource(state))

      {:trace, _source, _event, _detail} = message ->
        case trace_resource(message, state) do
          {:resource, updated} -> collect_pending_traces(updated)
          {:trace, updated} -> collect_pending_traces(updated)
        end

      {:trace, _source, _event, _detail, _extra} = message ->
        case trace_resource(message, state) do
          {:resource, updated} -> collect_pending_traces(updated)
          {:trace, updated} -> collect_pending_traces(updated)
        end
    after
      0 -> state
    end
  end

  defp await_cleanup(monitored, ports, deadline) do
    remaining_pids = Map.new(monitored, fn {pid, monitor} -> {monitor, pid} end)
    await_cleanup_resources(remaining_pids, ports, deadline)
  end

  defp await_cleanup_resources(remaining_pids, ports, deadline) do
    ports =
      Enum.reduce(ports, MapSet.new(), fn port, acc ->
        if port_open?(port), do: MapSet.put(acc, port), else: acc
      end)

    if map_size(remaining_pids) == 0 and MapSet.size(ports) == 0 do
      true
    else
      case remaining(deadline) do
        0 ->
          false

        wait ->
          receive do
            {:DOWN, monitor, :process, _pid, _reason}
            when is_map_key(remaining_pids, monitor) ->
              await_cleanup_resources(Map.delete(remaining_pids, monitor), ports, deadline)
          after
            min(wait, 10) -> await_cleanup_resources(remaining_pids, ports, deadline)
          end
      end
    end
  end

  defp process_info_list(pid, item) do
    case Process.info(pid, item) do
      {^item, values} when is_list(values) -> values
      _ -> []
    end
  end

  defp close_port(port) do
    if port_open?(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp port_open?(port) do
    case Port.info(port) do
      nil -> false
      _ -> true
    end
  end

  defp disable_trace(state) do
    Enum.each(state.traced_pids, fn pid ->
      try do
        :erlang.trace(pid, false, [:all])
      catch
        :error, :badarg -> :ok
      end
    end)
  end

  defp enable_resource_call_tracing do
    Enum.each(@resource_calls, fn mfa ->
      :erlang.trace_pattern(mfa, true, [:local])
    end)
  end

  defp failure(callback, target, reason) do
    {code, message} = failure_identity(callback, reason)
    stage = Failure.stage_for(code) |> elem(1)

    {:ok, diagnostic} =
      Diagnostic.new(
        target: target,
        stage: stage,
        severity: :error,
        code: Map.fetch!(@diagnostic_codes, {callback, reason}),
        message: message
      )

    {:error,
     Failure.new!(
       target: target,
       stage: stage,
       code: code,
       message: message,
       diagnostics: [diagnostic],
       retryable?: Failure.retryable?(code)
     )}
  end

  defp failure_identity(_callback, :cleanup),
    do: {:cleanup_unconfirmed, "extension callback cleanup could not be confirmed"}

  defp failure_identity(_callback, :resource),
    do: {:contract_violation, "extension callback resource limit was violated"}

  defp failure_identity(callback, :timeout)
       when callback in [:backend_id, :backend_version, :validate],
       do: {:contract_violation, "extension admission callback timed out"}

  defp failure_identity(:plan, :timeout),
    do: {:build_timeout, "extension plan callback timed out"}

  defp failure_identity(:finalize, :timeout),
    do: {:build_timeout, "extension finalize callback timed out"}

  defp failure_identity(_callback, :crash),
    do: {:contract_violation, "extension callback crashed"}

  defp failure_identity(_callback, :return),
    do: {:contract_violation, "extension callback returned an invalid value"}

  defp remaining(deadline), do: max(deadline - monotonic_ms(), 0)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
