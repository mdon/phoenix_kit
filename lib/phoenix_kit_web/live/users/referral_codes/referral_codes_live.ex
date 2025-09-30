defmodule PhoenixKitWeb.Live.Users.ReferralCodesLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.ReferralCodes
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate

  def mount(_params, _session, socket) do
    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load referral codes and stats
    codes = ReferralCodes.list_codes()
    system_stats = ReferralCodes.get_system_stats()
    config = ReferralCodes.get_config()

    socket =
      socket
      |> assign(:page_title, "Referral Codes")
      |> assign(:project_title, project_title)
      |> assign(:codes, codes)
      |> assign(:system_stats, system_stats)
      |> assign(:config, config)

    {:ok, socket}
  end

  def handle_event("delete_code", %{"id" => id}, socket) do
    code = ReferralCodes.get_code!(String.to_integer(id))

    case ReferralCodes.delete_code(code) do
      {:ok, _code} ->
        socket =
          socket
          |> put_flash(:info, "Referral code deleted successfully")
          |> assign(:codes, ReferralCodes.list_codes())
          |> assign(:system_stats, ReferralCodes.get_system_stats())

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to delete referral code")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_code_status", %{"id" => id}, socket) do
    code = ReferralCodes.get_code!(String.to_integer(id))
    new_status = !code.status

    case ReferralCodes.update_code(code, %{status: new_status}) do
      {:ok, _code} ->
        status_text = if new_status, do: "activated", else: "deactivated"

        socket =
          socket
          |> put_flash(:info, "Referral code #{status_text}")
          |> assign(:codes, ReferralCodes.list_codes())
          |> assign(:system_stats, ReferralCodes.get_system_stats())

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update referral code status")
        {:noreply, socket}
    end
  end

  defp format_expiration_date(nil), do: "No expiration"

  defp format_expiration_date(date) do
    date
    |> DateTime.to_date()
    |> UtilsDate.format_date_with_user_format()
  end

  defp code_status_class(code) do
    cond do
      !code.status -> "bg-gray-100 text-gray-800"
      ReferralCodes.expired?(code) -> "bg-red-100 text-red-800"
      ReferralCodes.usage_limit_reached?(code) -> "bg-yellow-100 text-yellow-800"
      true -> "bg-green-100 text-green-800"
    end
  end

  defp code_status_text(code) do
    cond do
      !code.status -> "Inactive"
      ReferralCodes.expired?(code) -> "Expired"
      ReferralCodes.usage_limit_reached?(code) -> "Limit Reached"
      true -> "Active"
    end
  end
end
