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
end
