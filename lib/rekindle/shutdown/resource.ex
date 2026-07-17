defmodule Rekindle.Shutdown.Resource do
  @moduledoc false

  @kinds [:discovery, :build, :helper, :publish, :browser, :desktop, :lease, :staging, :generic]
  @callbacks [:cancel, :notify, :release, :cleanup]

  @enforce_keys [:kind, :cancel, :notify, :release, :cleanup]
  defstruct @enforce_keys

  @type kind ::
          :discovery
          | :build
          | :helper
          | :publish
          | :browser
          | :desktop
          | :lease
          | :staging
          | :generic

  @type t :: %__MODULE__{
          kind: kind(),
          cancel: (-> term()) | nil,
          notify: (-> term()) | nil,
          release: (-> term()) | nil,
          cleanup: (-> term()) | nil
        }

  @spec new(kind(), keyword()) :: {:ok, t()} | :error
  def new(kind, options) do
    if kind in @kinds and Keyword.keyword?(options) do
      keys = Keyword.keys(options)

      build(kind, options, keys)
    else
      :error
    end
  end

  defp build(kind, options, keys) do
    if keys -- @callbacks == [] and length(keys) == length(Enum.uniq(keys)) do
      resource = %__MODULE__{
        kind: kind,
        cancel: Keyword.get(options, :cancel),
        notify: Keyword.get(options, :notify),
        release: Keyword.get(options, :release),
        cleanup: Keyword.get(options, :cleanup)
      }

      if Enum.all?(@callbacks, fn callback ->
           value = Map.fetch!(resource, callback)
           is_nil(value) or is_function(value, 0)
         end) and valid_shape?(resource) do
        {:ok, resource}
      else
        :error
      end
    else
      :error
    end
  end

  defp valid_shape?(%__MODULE__{kind: kind} = resource)
       when kind in [:discovery, :build, :helper, :publish, :generic],
       do: not is_nil(resource.cancel) and not is_nil(resource.cleanup)

  defp valid_shape?(%__MODULE__{kind: kind} = resource) when kind in [:browser, :desktop],
    do: not is_nil(resource.notify) and not is_nil(resource.cleanup)

  defp valid_shape?(%__MODULE__{kind: :lease} = resource), do: not is_nil(resource.release)
  defp valid_shape?(%__MODULE__{kind: :staging} = resource), do: not is_nil(resource.cleanup)
end
