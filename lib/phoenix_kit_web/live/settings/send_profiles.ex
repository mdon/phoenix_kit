defmodule PhoenixKitWeb.Live.Settings.SendProfiles do
  @moduledoc """
  Send profiles list page — under the core Email Sending settings
  (`/admin/settings/email-sending/profiles`).

  Each send profile references an Integrations connection and carries
  per-account send parameters (sender identity, rate limits, provider
  "advanced" options). At most one profile may be the service-wide default.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Send Profiles"))
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:current_path, get_current_path(socket.assigns.current_locale_base))
      |> assign(:send_profiles, [])
      |> assign(:show_confirm_modal, false)
      |> assign(:confirm_action, nil)
      |> assign(:confirm_target, nil)
      |> assign(:confirm_title, "")
      |> assign(:confirm_message, "")

    {:ok, socket}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :send_profiles, SendProfiles.list_send_profiles())}
  end

  def handle_event("make_default", %{"uuid" => uuid}, socket) do
    send_profile = SendProfiles.get_send_profile!(uuid)

    case SendProfiles.set_default_send_profile(send_profile) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Default send profile updated"))
         |> assign(:send_profiles, SendProfiles.list_send_profiles())}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not set default send profile"))}
    end
  end

  def handle_event("show_confirm", %{"action" => "delete", "uuid" => uuid}, socket) do
    {:noreply,
     socket
     |> assign(:show_confirm_modal, true)
     |> assign(:confirm_action, :delete)
     |> assign(:confirm_target, uuid)
     |> assign(:confirm_title, gettext("Delete send profile"))
     |> assign(
       :confirm_message,
       gettext("This send profile will be permanently deleted.")
     )}
  end

  def handle_event("hide_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_confirm_modal, false)
     |> assign(:confirm_action, nil)
     |> assign(:confirm_target, nil)}
  end

  def handle_event("confirm_action", _params, socket) do
    socket = assign(socket, :show_confirm_modal, false)

    case socket.assigns.confirm_action do
      :delete ->
        handle_delete(socket, socket.assigns.confirm_target)

      _ ->
        {:noreply, socket}
    end
  end

  defp handle_delete(socket, uuid) do
    send_profile = SendProfiles.get_send_profile!(uuid)

    case SendProfiles.delete_send_profile(send_profile) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Send profile deleted"))
         |> assign(:send_profiles, SendProfiles.list_send_profiles())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Cannot delete send profile"))}
    end
  end

  defp get_current_path(locale) do
    Routes.path("/admin/settings/email-sending/profiles", locale: locale)
  end
end
