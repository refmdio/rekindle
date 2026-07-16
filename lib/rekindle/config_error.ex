defmodule Rekindle.ConfigError do
  @moduledoc "A stable configuration-admission error."

  @enforce_keys [:path, :code, :message]
  defstruct contract_version: 1, path: [], code: :config_invalid, message: nil

  @type path_segment :: atom() | String.t() | non_neg_integer()

  @type t :: %__MODULE__{
          contract_version: 1,
          path: [path_segment()],
          code: atom(),
          message: String.t()
        }

  @spec new([path_segment()], atom(), String.t()) :: t()
  def new(path, code, message)
      when is_list(path) and is_atom(code) and is_binary(message) do
    %__MODULE__{path: path, code: code, message: message}
  end
end
