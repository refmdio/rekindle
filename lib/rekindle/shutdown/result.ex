defmodule Rekindle.Shutdown.Result do
  @moduledoc false

  @enforce_keys [:status, :failures]
  defstruct @enforce_keys

  @type t :: %__MODULE__{status: :clean | :uncertain, failures: [Rekindle.Failure.t()]}

  @spec new([Rekindle.Failure.t()]) :: t()
  def new(failures) do
    failures = Enum.uniq_by(failures, &{&1.target, &1.stage, &1.code, &1.message})
    %__MODULE__{status: if(failures == [], do: :clean, else: :uncertain), failures: failures}
  end
end
