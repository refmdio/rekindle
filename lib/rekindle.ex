defmodule Rekindle do
  @moduledoc """
  Phoenix-native build system and development runtime for GPUI applications.

  Its public APIs expose the build and runtime contracts shared by Phoenix
  hosts and GPUI clients.
  """

  @typedoc "A Rekindle build target."
  @type target :: :web | :desktop

  @type build_mode :: :dev | :release
  @type support_level :: Rekindle.SupportLevel.t()
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

  @spec subscribe(otp_app()) :: {:ok, reference()} | {:error, :not_running}
  def subscribe(otp_app) when is_atom(otp_app) and otp_app not in [nil, true, false] do
    case Registry.lookup(Rekindle.RuntimeRegistry, {:events, otp_app}) do
      [{pid, _value}] -> Rekindle.EventBus.subscribe(pid)
      [] -> event_bus_unavailable()
    end
  end

  def subscribe(_otp_app), do: raise(ArgumentError, "otp_app must be an application atom")

  @spec unsubscribe(otp_app(), reference()) :: :ok | {:error, :not_owner}
  def unsubscribe(otp_app, reference)
      when is_atom(otp_app) and otp_app not in [nil, true, false] and is_reference(reference) do
    case Registry.lookup(Rekindle.RuntimeRegistry, {:events, otp_app}) do
      [{pid, _value}] -> Rekindle.EventBus.unsubscribe(pid, self(), reference)
      [] -> :ok
    end
  end

  def unsubscribe(_otp_app, _reference),
    do: raise(ArgumentError, "otp_app and subscription reference are invalid")

  @spec build(otp_app(), target(), mode: build_mode()) ::
          {:ok, Rekindle.BuildResult.t()} | {:error, Rekindle.Failure.t()}
  def build(otp_app, target, mode: mode)
      when is_atom(otp_app) and otp_app not in [nil, true, false] and
             target in [:web, :desktop] and mode in [:dev, :release],
      do: Rekindle.BuildFacade.build(otp_app, target, mode)

  def build(_otp_app, _target, _options),
    do: raise(ArgumentError, "build requires an OTP application, target, and dev or release mode")

  @spec current(otp_app(), target()) :: {:ok, Rekindle.GenerationRef.t()} | :none
  def current(otp_app, target)
      when is_atom(otp_app) and otp_app not in [nil, true, false] and
             target in [:web, :desktop],
      do: Rekindle.BuildFacade.current(otp_app, target)

  def current(_otp_app, _target),
    do: raise(ArgumentError, "current requires an OTP application and target")

  defp event_bus_unavailable do
    {:error, :not_running}
  end
end
