defmodule Rekindle do
  use Supervisor

  @moduledoc """
  Mix-first tooling for Rust UI applications in Elixir and Phoenix projects.
  """

  alias Rekindle.Config

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) do
    otp_app = Keyword.fetch!(options, :otp_app)
    Supervisor.start_link(__MODULE__, otp_app)
  end

  @impl Supervisor
  def init(_otp_app), do: Supervisor.init([], strategy: :one_for_one)

  @doc """
  Builds artifacts for an enabled target.

  The owning OTP application must be supplied with `:otp_app`. The optional
  `:profile` is either `:dev` or `:release`; it defaults to `:dev`.
  """
  @spec build(:web | :desktop, keyword()) ::
          {:ok, Rekindle.Build.Result.t()}
          | {:error, Config.Error.t() | Rekindle.Build.Error.t() | Rekindle.Cargo.Error.t()}
  def build(target, options \\ []) do
    with {:ok, otp_app} <- fetch_otp_app(options),
         {:ok, project} <- Config.load(otp_app, options) do
      Rekindle.Build.run(project, target, options)
    end
  end

  defp fetch_otp_app(options) do
    case Keyword.fetch(options, :otp_app) do
      {:ok, otp_app} when is_atom(otp_app) ->
        {:ok, otp_app}

      _ ->
        {:error,
         Rekindle.Build.Error.new(
           :missing_otp_app,
           "expected :otp_app to name the application that owns the Rekindle configuration"
         )}
    end
  end
end
