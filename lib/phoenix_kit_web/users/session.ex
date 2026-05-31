defmodule PhoenixKitWeb.Users.Session do
  @moduledoc """
  Controller for handling user session management.

  This controller manages user login and logout operations, including:
  - Creating new sessions via email/password authentication
  - Handling post-registration and password update flows
  - Session termination (logout)
  - GET-based logout for direct URL access

  ## Security Features

  - Prevents user enumeration by not disclosing whether an email is registered
  - Supports remember me functionality via UserAuth module
  - Session renewal on login/logout to prevent fixation attacks
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: UserAuth
  alias PhoenixKitWeb.Users.MultiSession

  def create(conn, %{"_action" => "registered"} = params) do
    create(conn, params, "Account created successfully!")
  end

  def create(conn, %{"_action" => "password_updated"} = params) do
    conn
    |> put_session(:user_return_to, Routes.path("/dashboard/settings"))
    |> create(params, "Password updated successfully!")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  defp create(conn, %{"user" => user_params}, info) do
    %{"password" => password} = user_params
    # Support both old "email" field and new "email_or_username" field for backwards compatibility
    email_or_username = user_params["email_or_username"] || user_params["email"]
    ip_address = IpAddress.extract_from_conn(conn)

    case Auth.get_user_by_email_or_username_and_password(email_or_username, password, ip_address) do
      {:ok, %Auth.User{is_active: false}} ->
        # Valid credentials but account is inactive
        conn
        |> put_flash(
          :error,
          "Your account is currently inactive. Please contact the team if you believe this is an error."
        )
        |> put_flash(:email_or_username, String.slice(email_or_username, 0, 160))
        |> redirect(to: Routes.path("/users/log-in"))

      {:ok, user} ->
        # Valid credentials and active account
        conn
        |> maybe_store_return_to_from_params(user_params)
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      {:error, :rate_limit_exceeded} ->
        # Rate limit exceeded - show specific error message
        conn
        |> put_flash(:error, "Too many login attempts. Please try again later.")
        |> put_flash(:email_or_username, String.slice(email_or_username, 0, 160))
        |> redirect(to: Routes.path("/users/log-in"))

      {:error, :invalid_credentials} ->
        # Invalid credentials (wrong email/username or password)
        # In order to prevent user enumeration attacks, don't disclose whether the email/username is registered.
        conn
        |> put_flash(:error, "Invalid email/username or password")
        |> put_flash(:email_or_username, String.slice(email_or_username, 0, 160))
        |> redirect(to: Routes.path("/users/log-in"))
    end
  end

  # Logout: "all" drains the whole stack; otherwise log out the active account only
  # (falling back to root) unless root is active, in which case full logout runs.
  def delete(conn, %{"all" => _} = _params) do
    conn
    |> MultiSession.delete_all_stack_tokens()
    |> put_flash(:info, "Logged out of all accounts.")
    |> UserAuth.log_out_user()
  end

  def delete(conn, _params) do
    case MultiSession.log_out_active(conn) do
      {:switched, conn, user} ->
        conn
        |> put_flash(:info, "Logged out. Now signed in as #{user.email}.")
        |> redirect(to: Routes.path("/"))

      {:full, conn} ->
        conn
        |> put_flash(:info, "Logged out successfully.")
        |> UserAuth.log_out_user()
    end
  end

  # --- multi-session helpers ---

  defp with_gate(conn, _params, fun) do
    if MultiSession.gate_allowed?(get_session(conn)) do
      fun.(conn)
    else
      conn
      |> put_status(:forbidden)
      |> put_flash(:error, "Multi-account switching is not available.")
      |> redirect(to: Routes.path("/"))
    end
  end

  defp redirect_back(conn, params) do
    return_to = params["return_to"]

    if is_binary(return_to) and String.starts_with?(return_to, "/") and
         not String.starts_with?(return_to, "//") do
      redirect(conn, to: return_to)
    else
      redirect(conn, to: Routes.path("/"))
    end
  end

  # Store return_to from form params (e.g., guest checkout → login → back to checkout)
  defp maybe_store_return_to_from_params(conn, %{"return_to" => return_to})
       when is_binary(return_to) and return_to != "" do
    if String.starts_with?(return_to, "/") and not String.starts_with?(return_to, "//") do
      put_session(conn, :user_return_to, return_to)
    else
      conn
    end
  end

  defp maybe_store_return_to_from_params(conn, _params), do: conn

  # Support GET logout for direct URL access
  def get_logout(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end

  def add_account(conn, %{"user" => %{"password" => password} = user_params} = params) do
    email_or_username = user_params["email_or_username"] || user_params["email"]

    with_gate(conn, params, fn conn ->
      case MultiSession.add_account(conn, email_or_username, password) do
        {:ok, conn} ->
          conn |> put_flash(:info, "Account added.") |> redirect_back(params)

        {:error, :stack_full} ->
          conn
          |> put_flash(:error, "Maximum number of accounts reached.")
          |> redirect_back(params)

        {:error, _reason} ->
          conn
          |> put_flash(:error, "Invalid email/username or password.")
          |> redirect_back(params)
      end
    end)
  end

  def set_active_account(conn, %{"ref" => ref} = params) do
    with_gate(conn, params, fn conn ->
      case MultiSession.switch_to(conn, ref) do
        {:ok, conn, user} ->
          conn |> put_flash(:info, "Switched to #{user.email}.") |> redirect_back(params)

        {:error, _reason} ->
          conn |> put_flash(:error, "Could not switch account.") |> redirect_back(params)
      end
    end)
  end

  def remove_account(conn, %{"ref" => ref} = params) do
    with_gate(conn, params, fn conn ->
      case MultiSession.remove_account(conn, ref) do
        {:ok, conn} ->
          conn |> put_flash(:info, "Account removed.") |> redirect_back(params)

        {:error, :cannot_remove_root} ->
          conn
          |> put_flash(:error, "Cannot remove your primary account.")
          |> redirect_back(params)

        {:error, _reason} ->
          conn |> put_flash(:error, "Could not remove account.") |> redirect_back(params)
      end
    end)
  end
end
