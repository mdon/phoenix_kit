defmodule PhoenixKitWeb.Live.ReferralCodeFormLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.ReferralCodes
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth

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
      |> assign(:search_results, [])
      |> assign(:selected_beneficiary, nil)
      |> load_code_data(mode, code_id)
      |> load_form_data()

    {:ok, socket}
  end

  def handle_event("validate_code", params, socket) do
    # Extract referral_codes params (note: plural form), ignoring search params  
    code_params = Map.get(params, "referral_codes", %{})
    
    # Add beneficiary if selected
    updated_params = case socket.assigns.selected_beneficiary do
      nil -> code_params
      beneficiary -> Map.put(code_params, "beneficiary", beneficiary.id)
    end
    
    # Create changeset for validation
    changeset =
      case socket.assigns.mode do
        :new -> ReferralCodes.changeset(%ReferralCodes{}, updated_params)
        :edit -> ReferralCodes.changeset(socket.assigns.code, updated_params)
      end
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:changeset, changeset)

    {:noreply, socket}
  end

  def handle_event("save_code", params, socket) do
    # Extract referral_codes params (note: plural form) and add selected beneficiary
    code_params = Map.get(params, "referral_codes", %{})
    
    # Ensure beneficiary is included if selected
    updated_code_params = case socket.assigns.selected_beneficiary do
      nil -> code_params
      beneficiary -> Map.put(code_params, "beneficiary", beneficiary.id)
    end
    
    case socket.assigns.mode do
      :new -> create_code(socket, updated_code_params)
      :edit -> update_code(socket, updated_code_params)
    end
  end

  def handle_event("generate_code", _params, socket) do
    random_code = ReferralCodes.generate_random_code()

    # Get current changeset changes and add the generated code
    current_changes = socket.assigns.changeset.changes
    updated_changes = Map.put(current_changes, :code, random_code)

    # Add beneficiary if selected
    final_changes = case socket.assigns.selected_beneficiary do
      nil -> updated_changes
      beneficiary -> Map.put(updated_changes, :beneficiary, beneficiary.id)
    end

    changeset =
      case socket.assigns.mode do
        :new -> ReferralCodes.changeset(%ReferralCodes{}, final_changes)
        :edit -> ReferralCodes.changeset(socket.assigns.code, final_changes)
      end

    socket =
      socket
      |> assign(:changeset, changeset)

    {:noreply, socket}
  end

  def handle_event("search_beneficiary", %{"search" => search_term}, socket) do
    search_results =
      if String.length(search_term) >= 2 do
        Auth.search_users(search_term)
      else
        []
      end

    socket =
      socket
      |> assign(:search_results, search_results)

    {:noreply, socket}
  end

  def handle_event("select_beneficiary", %{"user_id" => user_id}, socket) do
    # Find the selected user from search results
    selected_user =
      Enum.find(socket.assigns.search_results, fn user ->
        to_string(user.id) == user_id
      end)

    # Update the changeset with the selected beneficiary, preserving other changes
    current_changes = socket.assigns.changeset.changes
    updated_changes = Map.put(current_changes, :beneficiary, String.to_integer(user_id))

    changeset =
      case socket.assigns.mode do
        :new -> ReferralCodes.changeset(%ReferralCodes{}, updated_changes)
        :edit -> ReferralCodes.changeset(socket.assigns.code, updated_changes)
      end

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(:selected_beneficiary, selected_user)
      |> assign(:search_results, [])

    {:noreply, socket}
  end

  def handle_event("clear_beneficiary", _params, socket) do
    # Clear the beneficiary selection while preserving other changes
    current_changes = socket.assigns.changeset.changes
    updated_changes = Map.delete(current_changes, :beneficiary)

    changeset =
      case socket.assigns.mode do
        :new -> ReferralCodes.changeset(%ReferralCodes{}, updated_changes)
        :edit -> ReferralCodes.changeset(socket.assigns.code, updated_changes)
      end

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(:selected_beneficiary, nil)
      |> assign(:search_results, [])

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
    # Use repo query to preload beneficiary_user
    code = ReferralCodes.get_code!(code_id)
    # TODO: Add preload for beneficiary_user - for now we'll handle it in the loading
    assign(socket, :code, code)
  end

  defp load_form_data(socket) do
    code = socket.assigns.code || %ReferralCodes{}
    
    # For new codes, initialize with empty changeset
    # For edit mode, initialize changeset with current code data to pre-populate form
    initial_params = case socket.assigns.mode do
      :new -> %{}
      :edit -> %{
        "code" => code.code,
        "description" => code.description,
        "max_uses" => code.max_uses,
        "expiration_date" => code.expiration_date,
        "status" => code.status
      }
    end
    
    changeset = ReferralCodes.changeset(code, initial_params)

    # Load selected beneficiary if editing existing code with beneficiary ID
    selected_beneficiary =
      case code.beneficiary do
        nil -> nil
        beneficiary_id -> Auth.get_user_for_selection(beneficiary_id)
      end

    socket
    |> assign(:changeset, changeset)
    |> assign(:selected_beneficiary, selected_beneficiary)
  end

  defp create_code(socket, code_params) do
    # Add created_by field from current user and get user_id for validation
    {code_params_with_creator, user_id} =
      case socket.assigns.phoenix_kit_current_user do
        user when not is_nil(user) ->
          {Map.put(code_params, "created_by", user.id), user.id}
        _ ->
          # Try alternative scope pattern
          case socket.assigns do
            %{phoenix_kit_current_scope: %{user_id: user_id}} when not is_nil(user_id) ->
              {Map.put(code_params, "created_by", user_id), user_id}
            _ ->
              # This should not happen in normal operation
              IO.inspect(socket.assigns, label: "Socket assigns when current_user is nil")
              {code_params, nil}
          end
      end

    # Check user code creation limit before creating
    case user_id && ReferralCodes.validate_user_code_limit(user_id) do
      {:ok, :valid} ->
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

      {:error, limit_message} ->
        socket
        |> put_flash(:error, limit_message)

      nil ->
        # No user_id available, proceed without limit check
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
