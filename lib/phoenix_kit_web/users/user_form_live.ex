defmodule PhoenixKitWeb.Users.UserFormLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    user_id = params["id"]
    mode = if user_id, do: :edit, else: :new

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:user_id, user_id)
      |> assign(:page_title, page_title(mode))
      |> assign(:show_reset_password_modal, false)
      |> assign(:show_password_field, false)
      |> load_user_data(mode, user_id)
      |> load_form_data()

    {:ok, socket}
  end

  def handle_event("validate_user", %{"user" => user_params}, socket) do
    # Filter password from params if password field is not shown
    filtered_params =
      if socket.assigns.mode == :edit and not socket.assigns.show_password_field do
        Map.delete(user_params, "password")
      else
        user_params
      end

    changeset =
      case socket.assigns.mode do
        :new -> Auth.change_user_registration(%Auth.User{}, filtered_params)
        :edit -> Auth.change_user_registration(socket.assigns.user, filtered_params)
      end
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(:form_data, user_params)

    {:noreply, socket}
  end

  def handle_event("save_user", %{"user" => user_params}, socket) do
    case socket.assigns.mode do
      :new -> create_user(socket, user_params)
      :edit -> update_user(socket, user_params)
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/users"))}
  end

  def handle_event("show_reset_password_modal", _params, socket) do
    socket = assign(socket, :show_reset_password_modal, true)
    {:noreply, socket}
  end

  def handle_event("hide_reset_password_modal", _params, socket) do
    socket = assign(socket, :show_reset_password_modal, false)
    {:noreply, socket}
  end

  def handle_event("admin_reset_password", _params, socket) do
    user = socket.assigns.user

    case Auth.deliver_user_reset_password_instructions(
           user,
           &Routes.url("/users/reset-password/#{&1}")
         ) do
      {:ok, _} ->
        socket =
          socket
          |> put_flash(
            :info,
            "Password reset email sent to #{user.email}. The user will receive instructions to reset their password."
          )
          |> assign(:show_reset_password_modal, false)

        {:noreply, socket}

      {:error, _reason} ->
        socket =
          put_flash(socket, :error, "Failed to send password reset email. Please try again.")

        {:noreply, socket}
    end
  end

  def handle_event("toggle_password_field", _params, socket) do
    new_show_password_field = !socket.assigns.show_password_field

    socket =
      socket
      |> assign(:show_password_field, new_show_password_field)
      |> reload_changeset_with_password(new_show_password_field)

    {:noreply, socket}
  end

  defp create_user(socket, user_params) do
    case Auth.register_user(user_params) do
      {:ok, user} ->
        # Optionally send confirmation email
        case Auth.deliver_user_confirmation_instructions(
               user,
               &Routes.url("/users/confirm/#{&1}")
             ) do
          {:ok, _} -> :ok
          # Continue even if email fails
          {:error, _} -> :ok
        end

        socket =
          socket
          |> put_flash(:info, "User created successfully. Confirmation email sent.")
          |> push_navigate(to: Routes.path("/admin/users"))

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        socket =
          socket
          |> assign(:changeset, changeset)
          |> assign(:form_data, user_params)

        {:noreply, socket}
    end
  end

  defp update_user(socket, user_params) do
    user = socket.assigns.user
    show_password_field = socket.assigns.show_password_field

    # Check if password update is needed
    password_provided =
      show_password_field and Map.has_key?(user_params, "password") and
        user_params["password"] != nil and String.trim(user_params["password"]) != ""

    if password_provided do
      # Update both profile and password
      case update_profile_and_password(user, user_params) do
        {:ok, _updated_user} ->
          socket =
            socket
            |> put_flash(:info, "User profile and password updated successfully.")
            |> push_navigate(to: Routes.path("/admin/users"))

          {:noreply, socket}

        {:error, changeset} ->
          socket =
            socket
            |> assign(:changeset, changeset)
            |> assign(:form_data, user_params)

          {:noreply, socket}
      end
    else
      # Update profile only (exclude password)
      profile_params = Map.delete(user_params, "password")

      case Auth.update_user_profile(user, profile_params) do
        {:ok, _user} ->
          socket =
            socket
            |> put_flash(:info, "User updated successfully.")
            |> push_navigate(to: Routes.path("/admin/users"))

          {:noreply, socket}

        {:error, %Ecto.Changeset{} = changeset} ->
          socket =
            socket
            |> assign(:changeset, changeset)
            |> assign(:form_data, user_params)

          {:noreply, socket}
      end
    end
  end

  defp load_user_data(socket, :new, _user_id) do
    assign(socket, :user, %Auth.User{})
  end

  defp load_user_data(socket, :edit, user_id) do
    user = Auth.get_user!(user_id)
    assign(socket, :user, user)
  end

  defp load_form_data(%{assigns: %{mode: :new}} = socket) do
    changeset = Auth.change_user_registration(%Auth.User{}, %{})

    socket
    |> assign(:changeset, changeset)
    |> assign(:form_data, %{
      "email" => "",
      "password" => "",
      "first_name" => "",
      "last_name" => ""
    })
  end

  defp load_form_data(%{assigns: %{mode: :edit, user: user}} = socket) do
    changeset = Auth.change_user_registration(user, %{})

    socket
    |> assign(:changeset, changeset)
    |> assign(:form_data, %{
      "email" => user.email || "",
      "first_name" => user.first_name || "",
      "last_name" => user.last_name || ""
    })
  end

  defp page_title(:new), do: "Create User"
  defp page_title(:edit), do: "Edit User"

  defp reload_changeset_with_password(socket, show_password_field) do
    case socket.assigns.mode do
      :new ->
        # For new users, password is always required
        socket

      :edit ->
        # For edit mode, reload changeset to include/exclude password field
        user = socket.assigns.user
        form_data = socket.assigns.form_data || %{}

        # Create changeset with or without password validation
        changeset =
          if show_password_field do
            # Include password in changeset when field is shown
            Auth.change_user_registration(user, form_data)
          else
            # Standard profile changeset when password field is hidden
            Auth.change_user_registration(user, Map.delete(form_data, "password"))
          end

        assign(socket, :changeset, changeset)
    end
  end

  defp update_profile_and_password(user, user_params) do
    # First validate profile update
    profile_params = Map.delete(user_params, "password")

    case Auth.update_user_profile(user, profile_params) do
      {:ok, updated_user} ->
        # If profile update succeeded, update password
        password_params = Map.take(user_params, ["password"])

        case Auth.admin_update_user_password(updated_user, password_params) do
          {:ok, final_user} ->
            {:ok, final_user}

          {:error, password_changeset} ->
            # If password update failed, return a combined changeset
            profile_changeset = Auth.change_user_registration(user, user_params)
            combined_changeset = merge_password_errors(profile_changeset, password_changeset)
            {:error, combined_changeset}
        end

      {:error, profile_changeset} ->
        # Profile update failed, return the profile changeset with password field
        {:error, profile_changeset}
    end
  end

  defp merge_password_errors(profile_changeset, password_changeset) do
    # Merge password errors into the profile changeset
    password_errors = password_changeset.errors

    Enum.reduce(password_errors, profile_changeset, fn {field, error}, acc ->
      Ecto.Changeset.add_error(acc, field, elem(error, 0), elem(error, 1))
    end)
  end
end
