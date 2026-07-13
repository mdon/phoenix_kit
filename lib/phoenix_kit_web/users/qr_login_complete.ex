defmodule PhoenixKitWeb.Users.QrLoginComplete do
  @moduledoc """
  Completion endpoint for QR device-handoff login.

  The desktop LiveView navigates here once its request is approved on the
  phone, carrying the one-time login token. This controller exchanges that
  token for the approved user's uuid (exactly once, via
  `PhoenixKit.Users.QrLogin.consume/1`) and establishes the session with
  PhoenixKit's own login machinery.

  Keyfob's login token is single-use and short-lived, so a replayed or
  stale URL lands on the login page rather than signing anyone in.
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.Users.Auth, as: Users
  alias PhoenixKit.Users.QrLogin, as: QrLoginContext
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: UserAuth

  def complete(conn, %{"token" => token} = params) do
    with true <- QrLoginContext.enabled?(),
         {:ok, user_uuid} <- QrLoginContext.consume(token),
         %{} = user <- Users.get_user(user_uuid) do
      conn
      # log_in_user/3 reads :user_return_to from the session for its redirect,
      # so stash the (sanitized) destination there before signing in.
      |> maybe_store_return_to(params["return_to"])
      |> put_flash(:info, gettext("Signed in with QR code."))
      |> UserAuth.log_in_user(user, login_params(params))
    else
      _ ->
        conn
        |> put_flash(:error, gettext("This QR sign-in link is invalid or has expired."))
        |> redirect(to: Routes.path("/users/log-in"))
    end
  end

  def complete(conn, _params) do
    conn
    |> put_flash(:error, gettext("This QR sign-in link is invalid or has expired."))
    |> redirect(to: Routes.path("/users/log-in"))
  end

  # Only "true" (from the browser's checkbox) opts into the persistent
  # remember-me cookie; anything else keeps a session-only login.
  defp login_params(%{"remember_me" => "true"}), do: %{"remember_me" => "true"}
  defp login_params(_params), do: %{}

  defp maybe_store_return_to(conn, return_to) do
    if is_binary(return_to) and Routes.local_path?(return_to) do
      put_session(conn, :user_return_to, return_to)
    else
      conn
    end
  end
end
