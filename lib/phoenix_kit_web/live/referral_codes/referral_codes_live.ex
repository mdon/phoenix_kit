defmodule PhoenixKitWeb.Live.ReferralCodesLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings
  alias PhoenixKit.ReferralCodes

  def mount(_params, session, socket) do
    # Get current path for navigation
    current_path = get_current_path(socket, session)

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load referral codes and system stats
    codes = ReferralCodes.list_codes()
    system_stats = ReferralCodes.get_system_stats()
    config = ReferralCodes.get_config()

    # Create initial changeset and form
    changeset = ReferralCodes.changeset(%ReferralCodes{}, %{})
    form = to_form(changeset, as: "referral_code")

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, "Referral Codes")
      |> assign(:project_title, project_title)
      |> assign(:codes, codes)
      |> assign(:system_stats, system_stats)
      |> assign(:config, config)
      |> assign(:show_form, false)
      |> assign(:form_code, nil)
      |> assign(:changeset, changeset)
      |> assign(:form, form)

    {:ok, socket}
  end

  def handle_event("show_new_form", _params, socket) do
    changeset = ReferralCodes.changeset(%ReferralCodes{}, %{})
    form = to_form(changeset, as: "referral_code")

    socket =
      socket
      |> assign(:show_form, true)
      |> assign(:form_code, nil)
      |> assign(:changeset, changeset)
      |> assign(:form, form)

    {:noreply, socket}
  end

  def handle_event("show_edit_form", %{"id" => id}, socket) do
    code = ReferralCodes.get_code!(String.to_integer(id))
    changeset = ReferralCodes.changeset(code, %{})
    form = to_form(changeset, as: "referral_code")

    socket =
      socket
      |> assign(:show_form, true)
      |> assign(:form_code, code)
      |> assign(:changeset, changeset)
      |> assign(:form, form)

    {:noreply, socket}
  end

  def handle_event("cancel_form", _params, socket) do
    changeset = ReferralCodes.changeset(%ReferralCodes{}, %{})
    form = to_form(changeset, as: "referral_code")

    socket =
      socket
      |> assign(:show_form, false)
      |> assign(:form_code, nil)
      |> assign(:changeset, changeset)
      |> assign(:form, form)

    {:noreply, socket}
  end

  def handle_event("generate_code", _params, socket) do
    random_code = ReferralCodes.generate_random_code()
    
    # Get current changeset data and update with generated code
    current_changes = socket.assigns.changeset.changes
    updated_attrs = Map.put(current_changes, :code, random_code)
    
    changeset = 
      case socket.assigns.form_code do
        nil -> ReferralCodes.changeset(%ReferralCodes{}, updated_attrs)
        code -> ReferralCodes.changeset(code, updated_attrs)
      end

    form = to_form(changeset, as: "referral_code")

    socket = 
      socket
      |> assign(:changeset, changeset)
      |> assign(:form, form)
      
    {:noreply, socket}
  end

  def handle_event("validate_code", %{"referral_code" => params}, socket) do
    changeset =
      case socket.assigns.form_code do
        nil -> 
          %ReferralCodes{}
          |> ReferralCodes.changeset(params)
          |> Map.put(:action, :validate)
        
        code -> 
          code
          |> ReferralCodes.changeset(params)
          |> Map.put(:action, :validate)
      end

    form = to_form(changeset, as: "referral_code")

    socket = 
      socket
      |> assign(:changeset, changeset)
      |> assign(:form, form)
      
    {:noreply, socket}
  end

  def handle_event("save_code", %{"referral_code" => params}, socket) do
    # Add created_by for new codes (get actual admin user ID from session)
    params_with_creator = if socket.assigns.form_code == nil do
      current_user_id = socket.assigns.phoenix_kit_current_user.id
      Map.put(params, "created_by", current_user_id)
    else
      params
    end

    case socket.assigns.form_code do
      nil ->
        case ReferralCodes.create_code(params_with_creator) do
          {:ok, _code} ->
            changeset = ReferralCodes.changeset(%ReferralCodes{}, %{})
            form = to_form(changeset, as: "referral_code")

            socket =
              socket
              |> put_flash(:info, "Referral code created successfully")
              |> assign(:show_form, false)
              |> assign(:form_code, nil)
              |> assign(:codes, ReferralCodes.list_codes())
              |> assign(:system_stats, ReferralCodes.get_system_stats())
              |> assign(:changeset, changeset)
              |> assign(:form, form)

            {:noreply, socket}

          {:error, %Ecto.Changeset{} = changeset} ->
            form = to_form(changeset, as: "referral_code")
            socket = 
              socket
              |> assign(:changeset, changeset)
              |> assign(:form, form)
            {:noreply, socket}
        end

      code ->
        case ReferralCodes.update_code(code, params_with_creator) do
          {:ok, _code} ->
            changeset = ReferralCodes.changeset(%ReferralCodes{}, %{})
            form = to_form(changeset, as: "referral_code")

            socket =
              socket
              |> put_flash(:info, "Referral code updated successfully")
              |> assign(:show_form, false)
              |> assign(:form_code, nil)
              |> assign(:codes, ReferralCodes.list_codes())
              |> assign(:system_stats, ReferralCodes.get_system_stats())
              |> assign(:changeset, changeset)
              |> assign(:form, form)

            {:noreply, socket}

          {:error, %Ecto.Changeset{} = changeset} ->
            form = to_form(changeset, as: "referral_code")
            socket = 
              socket
              |> assign(:changeset, changeset)
              |> assign(:form, form)
            {:noreply, socket}
        end
    end
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

  defp get_current_path(_socket, _session) do
    "/phoenix_kit/admin/referral-codes"
  end

  defp format_expiration_date(nil), do: "No expiration"
  defp format_expiration_date(date) do
    date
    |> DateTime.to_date()
    |> Date.to_string()
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