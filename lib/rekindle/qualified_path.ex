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
    table = :ets.new(__MODULE__, [:named_table, :set, :public, read_concurrency: true])
    {:ok, table}
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
    true = :ets.insert(__MODULE__, {token, expanded})
    %__MODULE__{token: token, access: access}
  end

  @doc false
  @spec resolve(t(), :read | :read_write) :: {:ok, Path.t()} | :error
  def resolve(%__MODULE__{token: token, access: granted}, requested)
      when requested in [:read, :read_write] do
    permitted? = granted == :read_write or requested == :read

    case permitted? && :ets.lookup(__MODULE__, token) do
      [{^token, path}] -> {:ok, path}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end
end
