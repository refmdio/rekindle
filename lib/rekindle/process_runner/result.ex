defmodule Rekindle.ProcessRunner.Result do
  @moduledoc false

  @enforce_keys [:execution, :stdout, :stderr]
  defstruct @enforce_keys
end
