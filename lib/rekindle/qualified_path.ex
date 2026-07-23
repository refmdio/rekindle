defmodule Rekindle.QualifiedPath do
  use GenServer

  @moduledoc """
  Opaque authority for a path qualified by Rekindle core.

  Target backends receive this handle instead of an arbitrary filesystem path.
  The token does not grant publication, activation, or artifact-store access.
  """

  @enforce_keys [:token, :access]
  defstruct [:token, :access]

  @opaque t :: %__MODULE__{token: reference(), access: :read | :read_write}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    {:ok, %{tokens: %{}, scopes: %{}, monitors: %{}}}
  end

  @doc false
  @spec with_scope((-> result)) :: result when result: var
  def with_scope(function) when is_function(function, 0) do
    key = {__MODULE__, :scope}

    if Process.get(key) do
      raise ArgumentError, "qualified path scopes cannot be nested"
    end

    scope = GenServer.call(__MODULE__, {:open_scope, self()})
    Process.put(key, scope)

    try do
      function.()
    after
      Process.delete(key)
      close_scope(scope)
    end
  end

  @doc false
  @spec issue(:read | :read_write) :: t()
  def issue(access) when access in [:read, :read_write] do
    %__MODULE__{token: make_ref(), access: access}
  end

  @doc false
  @spec issue(Path.t(), :read | :read_write) :: t()
  def issue(path, access) when is_binary(path) and access in [:read, :read_write] do
    expanded = Path.expand(path)
    token = make_ref()
    scope = Process.get({__MODULE__, :scope})

    if not is_reference(scope) do
      raise ArgumentError, "qualified paths require an active scope"
    end

    :ok = GenServer.call(__MODULE__, {:issue, scope, token, expanded, access})
    %__MODULE__{token: token, access: access}
  end

  @doc false
  @spec resolve(t(), :read | :read_write) :: {:ok, Path.t()} | :error
  def resolve(%__MODULE__{token: token}, requested)
      when requested in [:read, :read_write] do
    GenServer.call(__MODULE__, {:resolve, token, requested})
  catch
    :exit, _reason -> :error
  end

  def resolve(_path, _requested), do: :error

  @doc false
  @spec authority_size() :: non_neg_integer()
  def authority_size, do: GenServer.call(__MODULE__, :authority_size)

  @impl true
  def handle_call({:open_scope, owner}, _from, state) do
    scope = make_ref()
    monitor = Process.monitor(owner)
    entry = %{owner: owner, monitor: monitor, tokens: MapSet.new()}

    {:reply, scope,
     %{
       state
       | scopes: Map.put(state.scopes, scope, entry),
         monitors: Map.put(state.monitors, monitor, scope)
     }}
  end

  def handle_call({:issue, scope, token, path, access}, {owner, _tag}, state) do
    case Map.get(state.scopes, scope) do
      %{owner: ^owner, tokens: tokens} = entry ->
        entry = %{entry | tokens: MapSet.put(tokens, token)}

        {:reply, :ok,
         %{
           state
           | tokens: Map.put(state.tokens, token, %{path: path, access: access, scope: scope}),
             scopes: Map.put(state.scopes, scope, entry)
         }}

      _ ->
        {:reply, {:error, :invalid_scope}, state}
    end
  end

  def handle_call({:resolve, token, requested}, _from, state) do
    result =
      case Map.get(state.tokens, token) do
        %{path: path, access: :read_write} -> {:ok, path}
        %{path: path, access: :read} when requested == :read -> {:ok, path}
        _ -> :error
      end

    {:reply, result, state}
  end

  def handle_call({:close_scope, scope}, {owner, _tag}, state) do
    case Map.get(state.scopes, scope) do
      %{owner: ^owner} -> {:reply, :ok, drop_scope(state, scope)}
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call(:authority_size, _from, state), do: {:reply, map_size(state.tokens), state}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {scope, monitors} ->
        {:noreply, drop_scope(%{state | monitors: monitors}, scope, false)}
    end
  end

  defp close_scope(scope) do
    GenServer.call(__MODULE__, {:close_scope, scope})
  catch
    :exit, _reason -> :ok
  end

  defp drop_scope(state, scope, demonitor? \\ true) do
    case Map.pop(state.scopes, scope) do
      {nil, _scopes} ->
        state

      {%{monitor: monitor, tokens: tokens}, scopes} ->
        if demonitor?, do: Process.demonitor(monitor, [:flush])

        %{
          state
          | tokens: Enum.reduce(tokens, state.tokens, &Map.delete(&2, &1)),
            scopes: scopes,
            monitors: Map.delete(state.monitors, monitor)
        }
    end
  end
end
