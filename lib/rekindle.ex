defmodule Rekindle do
  @moduledoc """
  Phoenix-native build system and development runtime for GPUI applications.

  Its public APIs expose the build and runtime contracts shared by Phoenix
  hosts and GPUI clients.
  """

  @typedoc "A Rekindle build target."
  @type target :: :web | :desktop

  @type build_mode :: :dev | :release
  @type otp_app :: atom()

  @spec child_spec(otp_app: otp_app(), name: GenServer.name()) :: Supervisor.child_spec()
  def child_spec(options) when is_list(options) do
    allowed = [:otp_app, :name]
    keys = Keyword.keys(options)

    unless Keyword.keyword?(options) and Enum.sort(keys) == Enum.sort(allowed) and
             length(keys) == 2 do
      raise ArgumentError, "Rekindle.child_spec/1 requires exactly :otp_app and :name"
    end

    otp_app = Keyword.fetch!(options, :otp_app)
    name = Keyword.fetch!(options, :name)

    unless is_atom(otp_app) and otp_app not in [nil, true, false] do
      raise ArgumentError, ":otp_app must be an OTP application atom"
    end

    %{
      id: {__MODULE__, otp_app},
      start: {Rekindle.ProjectSupervisor, :start_link, [[otp_app: otp_app, name: name]]},
      restart: :permanent,
      shutdown: 30_000,
      type: :supervisor
    }
  end

  @spec subscribe(otp_app()) :: {:ok, reference()} | {:error, Rekindle.Failure.t()}
  def subscribe(otp_app) when is_atom(otp_app) do
    case Registry.lookup(Rekindle.RuntimeRegistry, {:events, otp_app}) do
      [{pid, _value}] -> Rekindle.EventBus.subscribe(pid)
      [] -> event_bus_unavailable()
    end
  end

  def subscribe(_otp_app), do: event_bus_unavailable()

  @spec unsubscribe(otp_app(), reference()) :: :ok
  def unsubscribe(otp_app, reference) when is_atom(otp_app) and is_reference(reference) do
    case Registry.lookup(Rekindle.RuntimeRegistry, {:events, otp_app}) do
      [{pid, _value}] -> Rekindle.EventBus.unsubscribe(pid, self(), reference)
      [] -> :ok
    end
  end

  def unsubscribe(_otp_app, _reference), do: :ok

  @spec build(otp_app(), target(), mode: build_mode()) ::
          {:ok, Rekindle.BuildResult.t()} | {:error, Rekindle.Failure.t()}
  def build(otp_app, target, options) do
    case options do
      [mode: mode] when mode in [:dev, :release] ->
        Rekindle.BuildFacade.build(otp_app, target, mode)

      _ ->
        invalid_build_request()
    end
  end

  @spec current(otp_app(), target()) :: {:ok, Rekindle.GenerationRef.t()} | :none
  def current(otp_app, target), do: Rekindle.BuildFacade.current(otp_app, target)

  defp event_bus_unavailable do
    {:error,
     Rekindle.Failure.new!(
       target: nil,
       stage: :internal,
       code: :unexpected_state,
       message: "Rekindle project event stream is unavailable"
     )}
  end

  defp invalid_build_request do
    {:error,
     Rekindle.Failure.new!(
       target: nil,
       stage: :configuration,
       code: :config_invalid,
       message: "Build options must contain exactly one dev or release mode"
     )}
  end
end
