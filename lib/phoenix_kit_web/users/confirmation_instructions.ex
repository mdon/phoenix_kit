defmodule PhoenixKitWeb.Users.ConfirmationInstructions do
  @moduledoc """
  LiveView for resending email confirmation instructions.

  Allows users to request a new confirmation email if they didn't receive
  the original or if the link expired. Only sends if the account exists
  and is not already confirmed.

  This page is also where the authentication gates park logged-in users
  whose email is not yet confirmed (when `require_email_confirmation` is
  on), so it moves them along as soon as confirmation happens:

  - On mount, an already-confirmed user is redirected onward immediately —
    covers a confirmation done elsewhere (or directly in the DB) followed
    by a refresh, since the user is reloaded from the DB on every mount.
  - While parked, the LiveView listens on this user's own confirmation topic
    for `{:user_confirmed, user}` (broadcast by both the email-link flow and
    the admin confirm action) and redirects onward live, no refresh needed —
    e.g. when the user clicks the emailed link in another tab. It is a
    per-user topic, not the site-wide admin users feed, so a parked
    non-admin never receives other users' structs.
  - A parked user can also fix a typo'd address instead of only resending to
    it: "Wrong email?" reveals the same change-email form Profile Settings
    uses (current password + new address), via `Auth.apply_user_email/3` +
    `Auth.deliver_user_update_email_instructions/3`. The emailed link points
    at `PhoenixKitWeb.Users.ConfirmEmailChange`
    (`/users/confirm/change-email/:token`), NOT the normal
    `/profile/settings/confirm-email/:token` landing page — that one sits
    behind the authenticated-AND-confirmed live_session, which an
    unconfirmed user fixing their email could never pass. Confirming the
    *new* address there changes the account's email AND confirms it in one
    step (`Auth.update_user_email/2` runs `confirm_changeset` either way),
    so there is no separate "now confirm again" round trip.

  "Onward" is `?return_to=` (stashed by the gate that parked them), then
  the session's `user_return_to`, then the `after_login_path` setting.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Utils.Routes

  def mount(params, session, socket) do
    user = socket.assigns[:phoenix_kit_current_user]
    destination = resolve_destination(params, session, socket)

    cond do
      user && user.confirmed_at ->
        {:ok, redirect(socket, to: destination)}

      is_nil(user) ->
        {:ok,
         socket
         |> assign(form: to_form(%{"email" => ""}, as: "user"))
         |> assign(awaiting_confirmation?: false)
         |> assign(destination: destination)}

      true ->
        # Subscribe FIRST, then re-read: a confirmation committed between the
        # on_mount user load and the subscribe would otherwise be missed, and
        # the page would sit there forever despite promising to continue
        # automatically. Re-reading after subscribing closes that window —
        # either the re-read sees it, or the broadcast reaches us.
        if connected?(socket), do: Events.subscribe_to_user_confirmation(user.uuid)

        if connected?(socket) and confirmed_since_mount?(user) do
          {:ok, redirect(socket, to: destination)}
        else
          {:ok,
           socket
           |> assign(form: to_form(%{"email" => user.email}, as: "user"))
           |> assign(awaiting_confirmation?: true)
           |> assign(destination: destination)
           |> assign(change_email?: false)
           |> assign(email_form: to_form(Auth.change_user_email(user), as: "email_change"))
           |> assign(email_form_current_password: nil)
           |> assign(confirmation_sent_at: Auth.get_last_confirmation_sent_at(user))}
        end
    end
  end

  defp confirmed_since_mount?(user) do
    case Auth.get_user(user.uuid) do
      %{confirmed_at: confirmed_at} -> not is_nil(confirmed_at)
      _ -> false
    end
  end

  def handle_event("send_instructions", %{"user" => %{"email" => submitted_email}}, socket) do
    # A parked visitor is already authenticated — resend to THEIR account,
    # never whatever the (still-editable) form field currently holds. Without
    # this, a logged-in unconfirmed user could edit the pre-filled field to
    # probe whether an arbitrary address exists, and get an honest answer
    # back (see below) instead of the anonymous form's deliberately vague one.
    email =
      if socket.assigns.awaiting_confirmation? do
        socket.assigns.phoenix_kit_current_user.email
      else
        submitted_email
      end

    # Throttle BEFORE the lookup and answer identically either way. This form
    # is public: only an existing unconfirmed account does work (insert a token,
    # send mail), so an unthrottled endpoint is both a targeted mail-flood
    # vector and a timing oracle for which addresses are registered.
    with :ok <- RateLimiter.check_confirmation_resend_rate_limit(email),
         %{} = user <- Auth.get_user_by_email(email) do
      Auth.deliver_user_confirmation_instructions(
        user,
        &Routes.url("/users/confirm/#{&1}")
      )
    end

    # The vague "if your email is in our system" wording exists to avoid
    # telling an anonymous visitor whether an address is registered. A parked
    # visitor is already logged in as that account — there is nothing left to
    # avoid revealing, and the hedge just reads as a wrong answer ("what do
    # you mean IF, I'm signed in").
    info =
      if socket.assigns.awaiting_confirmation? do
        gettext("We've sent a new confirmation link to %{email}.", email: email)
      else
        gettext(
          "If your email is in our system and it has not been confirmed yet, you will receive an email with instructions shortly."
        )
      end

    socket = put_flash(socket, :info, info)

    # A parked (logged-in, unconfirmed) user stays here so the live
    # auto-advance can fire once they click the emailed link; anonymous
    # visitors are sent on to the resolved destination.
    if socket.assigns.awaiting_confirmation? do
      sent_at =
        Auth.get_last_confirmation_sent_at(socket.assigns.phoenix_kit_current_user)

      {:noreply, assign(socket, confirmation_sent_at: sent_at)}
    else
      {:noreply, redirect(socket, to: socket.assigns.destination)}
    end
  end

  def handle_event("toggle_change_email", _params, socket) do
    if socket.assigns.awaiting_confirmation? do
      {:noreply, update(socket, :change_email?, &(!&1))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate_email_change", params, socket) do
    if socket.assigns.awaiting_confirmation? do
      {:noreply, do_validate_email_change(params, socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_email", params, socket) do
    if socket.assigns.awaiting_confirmation? do
      {:noreply, do_update_email(params, socket)}
    else
      {:noreply, socket}
    end
  end

  defp do_validate_email_change(
         %{"current_password" => password, "email_change" => user_params},
         socket
       ) do
    email_form =
      socket.assigns.phoenix_kit_current_user
      |> Auth.change_user_email(user_params)
      |> Map.put(:action, :validate)
      |> to_form(as: "email_change")

    socket
    |> assign(email_form: email_form)
    |> assign(email_form_current_password: password)
  end

  defp do_update_email(%{"current_password" => password, "email_change" => user_params}, socket) do
    user = socket.assigns.phoenix_kit_current_user

    case Auth.apply_user_email(user, password, user_params) do
      {:ok, applied_user} ->
        Auth.deliver_user_update_email_instructions(
          applied_user,
          user.email,
          &Routes.url("/users/confirm/change-email/#{&1}")
        )

        info =
          gettext(
            "We've sent a confirmation link to %{email}. Click it to finish updating your email — that also confirms your account.",
            email: applied_user.email
          )

        socket
        |> put_flash(:info, info)
        |> assign(change_email?: false)
        |> assign(email_form: to_form(Auth.change_user_email(user), as: "email_change"))
        |> assign(email_form_current_password: nil)

      {:error, changeset} ->
        socket
        |> assign(email_form: to_form(changeset, as: "email_change", action: :insert))
        |> assign(email_form_current_password: password)
    end
  end

  def handle_info({:user_confirmed, %{uuid: uuid}}, socket) do
    current = socket.assigns[:phoenix_kit_current_user]

    if current && current.uuid == uuid do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Email confirmed. Welcome!"))
       |> redirect(to: socket.assigns.destination)}
    else
      {:noreply, socket}
    end
  end

  # Defensive: the topic carries only this user's confirmation today.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # `:context` threads the socket's router so `"/"` is only used where the
  # host actually declares a root route. Without it the resolver synthesises
  # `"/"` literally, which 404s on any host that has no root route — the
  # configuration this entire branch exists to handle.
  defp resolve_destination(params, session, socket) do
    Routes.post_auth_path([params["return_to"], session["user_return_to"]],
      context: socket,
      scope: socket.assigns[:phoenix_kit_current_scope]
    )
  end
end
