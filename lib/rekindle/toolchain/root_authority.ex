defmodule Rekindle.Toolchain.RootAuthority do
  @moduledoc false

  use GenServer

  @type lease :: reference()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, nil, Keyword.put_new(options, :name, __MODULE__))
  end

  @spec register(term(), map()) :: :ok | {:error, :identity_changed}
  def register(key, identity), do: GenServer.call(__MODULE__, {:register, key, identity})

  @spec fetch(term()) :: {:ok, map()} | {:error, :unknown_authority}
  def fetch(key), do: GenServer.call(__MODULE__, {:fetch, key})

  @spec lease([{term(), map()}]) :: {:ok, lease()} | {:error, atom()}
  def lease(entries), do: GenServer.call(__MODULE__, {:lease, entries})

  @spec release(lease()) :: :ok
  def release(lease), do: GenServer.call(__MODULE__, {:release, lease})

  @spec leased?(lease()) :: boolean()
  def leased?(lease), do: GenServer.call(__MODULE__, {:leased?, lease})

  @doc false
  @spec stats() :: %{authorities: non_neg_integer(), leases: non_neg_integer()}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(_initial) do
    {:ok, %{authorities: %{}, leases: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:register, key, identity}, {owner, _tag}, state) when is_map(identity) do
    case state.authorities do
      %{^key => %{identity: ^identity} = authority} ->
        {authority, state} = add_issuer(authority, key, owner, state)
        {:reply, :ok, put_in(state, [:authorities, key], authority)}

      %{^key => _other} ->
        {:reply, {:error, :identity_changed}, state}

      %{} ->
        authority = %{identity: identity, issuers: %{}, leases: MapSet.new()}
        {authority, state} = add_issuer(authority, key, owner, state)
        {:reply, :ok, put_in(state, [:authorities, key], authority)}
    end
  end

  def handle_call({:register, _key, _identity}, _from, state),
    do: {:reply, {:error, :identity_changed}, state}

  def handle_call({:fetch, key}, _from, state) do
    case state.authorities do
      %{^key => authority} -> {:reply, {:ok, authority.identity}, state}
      %{} -> {:reply, {:error, :unknown_authority}, state}
    end
  end

  def handle_call({:lease, entries}, {owner, _tag}, state) do
    with {:ok, entries} <- normalize_entries(entries),
         :ok <- compatible_entries(state.authorities, entries) do
      lease = make_ref()
      monitor = Process.monitor(owner)

      authorities =
        Enum.reduce(entries, state.authorities, fn {key, identity}, authorities ->
          authority =
            Map.get(authorities, key, %{
              identity: identity,
              issuers: %{},
              leases: MapSet.new()
            })

          Map.put(authorities, key, %{authority | leases: MapSet.put(authority.leases, lease)})
        end)

      state = %{
        state
        | authorities: authorities,
          leases:
            Map.put(state.leases, lease, %{owner: owner, monitor: monitor, entries: entries}),
          monitors: Map.put(state.monitors, monitor, {:lease, lease})
      }

      {:reply, {:ok, lease}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release, lease}, _from, state) do
    case state.leases do
      %{^lease => _entry} -> {:reply, :ok, drop_lease(state, lease, true)}
      %{} -> {:reply, :ok, state}
    end
  end

  def handle_call({:leased?, lease}, _from, state) do
    {:reply, Map.has_key?(state.leases, lease), state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, %{authorities: map_size(state.authorities), leases: map_size(state.leases)}, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, monitor) do
      {:issuer, key, owner} ->
        {:noreply, drop_issuer(state, key, owner, monitor)}

      {:lease, lease} ->
        {:noreply, drop_lease(state, lease, false)}

      nil ->
        {:noreply, state}
    end
  end

  defp normalize_entries(entries) when is_list(entries) and entries != [] do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      {key, identity}, {:ok, normalized} when is_map(identity) ->
        case normalized do
          %{^key => ^identity} -> {:cont, {:ok, normalized}}
          %{^key => _other} -> {:halt, {:error, :identity_changed}}
          %{} -> {:cont, {:ok, Map.put(normalized, key, identity)}}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_authority}}
    end)
    |> case do
      {:ok, normalized} when map_size(normalized) > 0 ->
        {:ok, normalized |> Enum.sort_by(fn {key, _identity} -> :erlang.term_to_binary(key) end)}

      _ ->
        {:error, :invalid_authority}
    end
  end

  defp normalize_entries(_entries), do: {:error, :invalid_authority}

  defp compatible_entries(authorities, entries) do
    if Enum.all?(entries, fn {key, identity} ->
         case authorities do
           %{^key => %{identity: ^identity}} -> true
           %{^key => _other} -> false
           %{} -> true
         end
       end),
       do: :ok,
       else: {:error, :identity_changed}
  end

  defp add_issuer(authority, key, owner, state) do
    case authority.issuers do
      %{^owner => _monitor} ->
        {authority, state}

      %{} ->
        monitor = Process.monitor(owner)
        authority = %{authority | issuers: Map.put(authority.issuers, owner, monitor)}
        state = put_in(state, [:monitors, monitor], {:issuer, key, owner})
        {authority, state}
    end
  end

  defp drop_issuer(state, key, owner, monitor) do
    state = %{state | monitors: Map.delete(state.monitors, monitor)}

    case state.authorities do
      %{^key => authority} ->
        authority = %{authority | issuers: Map.delete(authority.issuers, owner)}

        if map_size(authority.issuers) == 0 and MapSet.size(authority.leases) == 0,
          do: %{state | authorities: Map.delete(state.authorities, key)},
          else: put_in(state, [:authorities, key], authority)

      %{} ->
        state
    end
  end

  defp drop_lease(state, lease, demonitor?) do
    case Map.pop(state.leases, lease) do
      {nil, _leases} ->
        state

      {%{monitor: monitor, entries: entries}, leases} ->
        if demonitor?, do: Process.demonitor(monitor, [:flush])

        state = %{
          state
          | leases: leases,
            monitors: Map.delete(state.monitors, monitor)
        }

        Enum.reduce(entries, state, fn {key, _identity}, acc ->
          case acc.authorities do
            %{^key => authority} ->
              authority = %{authority | leases: MapSet.delete(authority.leases, lease)}

              if MapSet.size(authority.leases) == 0 do
                remove_authority(acc, key, authority)
              else
                put_in(acc, [:authorities, key], authority)
              end

            %{} ->
              acc
          end
        end)
    end
  end

  defp remove_authority(state, key, authority) do
    monitors =
      Enum.reduce(authority.issuers, state.monitors, fn {_owner, monitor}, monitors ->
        Process.demonitor(monitor, [:flush])
        Map.delete(monitors, monitor)
      end)

    %{state | authorities: Map.delete(state.authorities, key), monitors: monitors}
  end
end
