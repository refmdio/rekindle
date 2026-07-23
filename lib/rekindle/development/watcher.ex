defmodule Rekindle.Development.Watcher do
  @moduledoc false

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  @impl GenServer
  def init(options) do
    source = Keyword.fetch!(options, :source)
    :ok = FileSystem.subscribe(source)
    send(self(), :initial_build)

    {:ok,
     %{
       source: GenServer.whereis(source),
       builder: Keyword.fetch!(options, :builder),
       root: options |> Keyword.fetch!(:root) |> Path.expand()
     }}
  end

  @impl GenServer
  def handle_info(:initial_build, state) do
    Rekindle.Development.Builder.rebuild(state.builder)
    {:noreply, state}
  end

  def handle_info({:file_event, source, {path, _events}}, %{source: source} = state) do
    case targets(state.root, path) do
      [] -> :ok
      targets -> Rekindle.Development.Builder.rebuild(state.builder, targets)
    end

    {:noreply, state}
  end

  def handle_info({:file_event, source, :stop}, %{source: source} = state) do
    {:stop, :watcher_stopped, state}
  end

  @doc false
  @spec targets(Path.t(), Path.t()) :: [:web | :desktop]
  def targets(root, path) do
    relative = path |> Path.expand() |> Path.relative_to(root)

    cond do
      Path.type(relative) == :absolute ->
        []

      relative == "target" or String.starts_with?(relative, "target/") ->
        []

      relative == ".git" or String.starts_with?(relative, ".git/") ->
        []

      relative == "public" or String.starts_with?(relative, "public/") ->
        [:web]

      relative == "src/bin/web.rs" ->
        [:web]

      relative == "src/bin/desktop.rs" ->
        [:desktop]

      relative == ".." or String.starts_with?(relative, "../") ->
        []

      true ->
        [:web, :desktop]
    end
  end
end
