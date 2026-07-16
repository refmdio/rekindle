defmodule Rekindle.Toolchain.RootAuthority do
  @moduledoc false

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(options, :name, __MODULE__))
  end

  @spec register(term(), map()) :: :ok | {:error, :identity_changed}
  def register(key, identity), do: GenServer.call(__MODULE__, {:register, key, identity})

  @spec fetch(term()) :: {:ok, map()} | {:error, :unknown_authority}
  def fetch(key), do: GenServer.call(__MODULE__, {:fetch, key})

  @impl true
  def init(authorities), do: {:ok, authorities}

  @impl true
  def handle_call({:register, key, identity}, _from, authorities) do
    case authorities do
      %{^key => ^identity} -> {:reply, :ok, authorities}
      %{^key => _other} -> {:reply, {:error, :identity_changed}, authorities}
      %{} -> {:reply, :ok, Map.put(authorities, key, identity)}
    end
  end

  def handle_call({:fetch, key}, _from, authorities) do
    case authorities do
      %{^key => identity} -> {:reply, {:ok, identity}, authorities}
      %{} -> {:reply, {:error, :unknown_authority}, authorities}
    end
  end
end
