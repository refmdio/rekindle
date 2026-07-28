defmodule Rekindle.Plugin.Spec do
  @moduledoc """
  Declarative requirements for one Rust UI plugin.

  The spec describes client generation and browser hosting. Rekindle retains
  ownership of Cargo execution, development processes, and artifact
  publication.
  """

  alias Rekindle.Plugin.Cargo

  defmodule Web do
    @moduledoc "Browser host requirements declared by a plugin."

    @enforce_keys [:graphics, :host, :style]
    defstruct [:graphics, :host, :style]

    @type t :: %__MODULE__{
            graphics: :webgpu | :webgl2,
            host: String.t(),
            style: String.t()
          }
  end

  @type target :: :web | :desktop
  @type file_map :: %{required(String.t()) => String.t()}

  @enforce_keys [
    :name,
    :dependency,
    :source,
    :files,
    :entries,
    :cargo,
    :toolchain,
    :web
  ]
  defstruct [:name, :dependency, :source, :files, :entries, :cargo, :toolchain, :web]

  @type t :: %__MODULE__{
          name: String.t(),
          dependency: String.t(),
          source: Rekindle.Priv.source(),
          files: file_map(),
          entries: %{required(target()) => String.t()},
          cargo: Cargo.t(),
          toolchain: String.t(),
          web: Web.t()
        }
end
