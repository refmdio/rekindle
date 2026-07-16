defmodule Rekindle do
  @moduledoc """
  Phoenix-native build system and development runtime for GPUI applications.

  The stable public API is introduced by the feature packages that implement
  the Rekindle build and runtime contracts.
  """

  @typedoc "A Rekindle build target."
  @type target :: :web | :desktop
end
