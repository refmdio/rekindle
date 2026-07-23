defmodule Rekindle.TargetHandler do
  @moduledoc false

  @callback build(
              Rekindle.Config.Project.t(),
              Rekindle.build_mode(),
              source_revision :: non_neg_integer()
            ) ::
              {:ok, Rekindle.BuildResult.t()} | {:error, Rekindle.Failure.t()}
end
