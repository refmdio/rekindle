defmodule Rekindle.Phoenix.PageRuntime do
  @moduledoc false

  @type development :: %{
          required(:socket_path) => String.t(),
          required(:project_session) => String.t(),
          required(:token) => String.t()
        }

  @spec resolve(atom(), module()) :: {:development, development()} | :production
  def resolve(otp_app, endpoint) do
    endpoint_config = Application.get_env(otp_app, endpoint, [])
    dev_config = Application.get_env(otp_app, :rekindle_dev, [])

    if Keyword.get(endpoint_config, :code_reloader, false) and
         Keyword.get(dev_config, :enabled, false) do
      {:development, fetch_session!(otp_app)}
    else
      :production
    end
  end

  defp fetch_session!(otp_app) do
    case Application.fetch_env(otp_app, :rekindle_page_runtime) do
      {:ok,
       [
         socket_path: socket_path,
         project_session: project_session,
         token: token
       ]}
      when is_binary(socket_path) and is_binary(project_session) and is_binary(token) ->
        validate_session!(socket_path, project_session, token)

      _ ->
        raise ArgumentError,
              "development gpui_page requires the active Rekindle page runtime session"
    end
  end

  defp validate_session!(socket_path, project_session, token) do
    unless String.starts_with?(socket_path, "/") and
             Regex.match?(~r/\A[0-9a-f]{32}\z/, project_session) and
             byte_size(token) in 32..256 and String.valid?(token) do
      raise ArgumentError, "invalid Rekindle page runtime session"
    end

    %{socket_path: socket_path, project_session: project_session, token: token}
  end
end
