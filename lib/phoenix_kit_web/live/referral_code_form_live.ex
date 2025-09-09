defmodule PhoenixKitWeb.Live.ReferralCodeFormLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.ReferralCodes
  alias PhoenixKit.Settings

  def mount(params, session, socket) do
    code_id = params["id"]
    mode = if code_id, do: :edit, else: :new

    # Get current path for navigation
    current_path = get_current_path(socket, session, mode, code_id)

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:code_id, code_id)
      |> assign(:current_path, current_path)
      |> assign(:page_title, page_title(mode))
      |> assign(:project_title, project_title)
      |> load_code_data(mode, code_id)
      |> load_form_data()

    {:ok, socket}
  end

  def handle_event("validate_code", %{"referral_code" => code_params}, socket) do
    changeset =
      case socket.assigns.mode do
        :new -> ReferralCodes.changeset(%ReferralCodes{}, code_params)
        :edit -> ReferralCodes.changeset(socket.assigns.code, code_params)
      end
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(:form_data, code_params)

    {:noreply, socket}
  end

  def handle_event("save_code", %{"referral_code" => code_params}, socket) do
    case socket.assigns.mode do
      :new -> create_code(socket, code_params)
      :edit -> update_code(socket, code_params)
    end
  end

  def handle_event("generate_code", _params, socket) do
    random_code = ReferralCodes.generate_random_code()
    
    updated_params = Map.put(socket.assigns.form_data || %{}, "code", random_code)
    
    changeset =
      case socket.assigns.mode do
        :new -> ReferralCodes.changeset(%ReferralCodes{}, updated_params)
        :edit -> ReferralCodes.changeset(socket.assigns.code, updated_params)
      end

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(:form_data, updated_params)

    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, push_navigate(socket, to: "/phoenix_kit/admin/referral-codes")}
  end

  # Private functions

  defp load_code_data(socket, :new, _code_id) do
    assign(socket, :code, nil)
  end

  defp load_code_data(socket, :edit, code_id) do
    code = ReferralCodes.get_code!(code_id)
    assign(socket, :code, code)
  end

  defp load_form_data(socket) do
    code = socket.assigns.code || %ReferralCodes{}
    changeset = ReferralCodes.changeset(code, %{})
    
    socket
    |> assign(:changeset, changeset)
    |> assign(:form_data, %{})
  end

  defp create_code(socket, code_params) do
    # Add created_by field if current user is available
    code_params_with_creator =
      case socket.assigns[:phoenix_kit_current_scope] do
        %{user_id: user_id} when not is_nil(user_id) ->
          Map.put(code_params, "created_by", user_id)
        _ ->
          code_params
      end

    case ReferralCodes.create_code(code_params_with_creator) do
      {:ok, _code} ->
        socket
        |> put_flash(:info, "Referral code created successfully!")
        |> push_navigate(to: "/phoenix_kit/admin/referral-codes")

      {:error, changeset} ->
        socket
        |> assign(:changeset, changeset)
        |> put_flash(:error, "Failed to create referral code. Please check the errors below.")
    end
    |> then(&{:noreply, &1})
  end

  defp update_code(socket, code_params) do
    case ReferralCodes.update_code(socket.assigns.code, code_params) do
      {:ok, _code} ->
        socket
        |> put_flash(:info, "Referral code updated successfully!")
        |> push_navigate(to: "/phoenix_kit/admin/referral-codes")

      {:error, changeset} ->
        socket
        |> assign(:changeset, changeset)
        |> put_flash(:error, "Failed to update referral code. Please check the errors below.")
    end
    |> then(&{:noreply, &1})
  end

  defp page_title(:new), do: "New Referral Code"
  defp page_title(:edit), do: "Edit Referral Code"

  defp get_current_path(_socket, _session, mode, code_id) do
    case mode do
      :new -> "/phoenix_kit/admin/referral-codes/new"
      :edit -> "/phoenix_kit/admin/referral-codes/edit/#{code_id}"
    end
  end
end