defmodule Rekindle.Phoenix.Components do
  @moduledoc "Phoenix page marker for a body-owned GPUI application."

  use Phoenix.Component

  alias Rekindle.Phoenix.PageRuntime

  attr(:otp_app, :atom, required: true)
  attr(:endpoint, :atom, required: true)

  @doc "Renders the single Rekindle page marker for a dedicated GPUI page."
  @spec gpui_page(Phoenix.LiveView.Socket.assigns()) :: Phoenix.LiveView.Rendered.t()
  def gpui_page(assigns) do
    case PageRuntime.resolve(assigns.otp_app, assigns.endpoint) do
      {:development, session} ->
        assigns
        |> assign(:runtime_url, "/_rekindle/runtime.js?session=#{session.project_session}")
        |> assign(:socket_path, session.socket_path)
        |> assign(:project_session, session.project_session)
        |> assign(:token, session.token)
        |> development_marker()

      :production ->
        assigns
        |> assign(
          :entry_url,
          Phoenix.VerifiedRoutes.static_path(assigns.endpoint, "/rekindle/entry.js")
        )
        |> production_marker()
    end
  end

  defp development_marker(assigns) do
    ~H"""
    <script
      type="module"
      src={@runtime_url}
      data-rekindle-page="v1"
      data-rekindle-socket={@socket_path}
      data-rekindle-project-session={@project_session}
      data-rekindle-token={@token}
    >
    </script>
    """
  end

  defp production_marker(assigns) do
    ~H"""
    <script type="module" src={@entry_url} data-rekindle-page="v1">
    </script>
    """
  end
end
