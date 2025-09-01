defmodule PhoenixKitWeb.Users.UserFormLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth

  def mount(params, session, socket) do
    user_id = params["id"]
    mode = if user_id, do: :edit, else: :new

    # Get current path for navigation
    current_path = get_current_path(socket, session, mode, user_id)

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:user_id, user_id)
      |> assign(:current_path, current_path)
      |> assign(:page_title, page_title(mode))
      |> assign(:show_reset_password_modal, false)
      |> load_user_data(mode, user_id)
      |> load_form_data()

    {:ok, socket}
  end

  def handle_event("validate_user", %{"user" => user_params}, socket) do
    changeset =
      case socket.assigns.mode do
        :new -> Auth.change_user_registration(%Auth.User{}, user_params)
        :edit -> Auth.change_user_registration(socket.assigns.user, user_params)
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
    {:noreply, push_navigate(socket, to: "/phoenix_kit/admin/users")}
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
           &"/phoenix_kit/users/reset-password/#{&1}"
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

  defp create_user(socket, user_params) do
    case Auth.register_user(user_params) do
      {:ok, user} ->
        # Optionally send confirmation email
        case Auth.deliver_user_confirmation_instructions(
               user,
               &"/phoenix_kit/users/confirm/#{&1}"
             ) do
          {:ok, _} -> :ok
          # Continue even if email fails
          {:error, _} -> :ok
        end

        socket =
          socket
          |> put_flash(:info, "User created successfully. Confirmation email sent.")
          |> push_navigate(to: "/phoenix_kit/admin/users")

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
    case Auth.update_user_profile(socket.assigns.user, user_params) do
      {:ok, _user} ->
        socket =
          socket
          |> put_flash(:info, "User updated successfully.")
          |> push_navigate(to: "/phoenix_kit/admin/users")

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        socket =
          socket
          |> assign(:changeset, changeset)
          |> assign(:form_data, user_params)

        {:noreply, socket}
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

  defp get_current_path(_socket, _session, :new, _user_id) do
    "/phoenix_kit/admin/users/new"
  end

  defp get_current_path(_socket, _session, :edit, user_id) do
    "/phoenix_kit/admin/users/edit/#{user_id}"
  end
end
