defmodule Rekindle.QualifiedPath do
  @moduledoc """
  Opaque authority for a path qualified by Rekindle core.

  Target backends receive this handle instead of an arbitrary filesystem path.
  The token does not grant publication, activation, or artifact-store access.
  """

  @enforce_keys [:token, :access]
  defstruct [:token, :access]

  @opaque t :: %__MODULE__{token: reference(), access: :read | :read_write}

  @doc false
  @spec issue(:read | :read_write) :: t()
  def issue(access) when access in [:read, :read_write] do
    %__MODULE__{token: make_ref(), access: access}
  end
end
