defmodule PhoenixKitWeb.Users.ReferralGate do
  @moduledoc """
  Where the invite-only gate parks an account that has not been admitted yet.

  With `referral_codes_required` on, an account can be created by any route —
  password, magic link, OAuth — but cannot use the application until it has
  satisfied the requirement. Every authentication gate redirects here; this
  page is what unblocks it. See the "Invite-only access gate" section of
  `PhoenixKit.Users.Referrals` for the full rule set.

  Deliberate properties, all of them inherited from the same reasoning that
  hardened the registration form:

  - **Submit-only.** There is no `phx-change`, so a code is checked when the
    user says they are done, not on every keystroke. Per-keystroke checking
    both burns the rate limit on half-typed codes and hands an attacker a much
    faster oracle.
  - **One message for every failure.** Wrong, expired, inactive, used up — all
    of them read the same. Distinguishing them confirms which guesses named a
    real code. Operators get the real reason from `Logger.debug`.
  - **Limited per account as well as per IP.** This screen is behind login, so
    an IP-keyed limit alone is defeated by making another account.

  A user who cannot get a code is not stranded: log-out is reachable from here,
  and it is deliberately the only other thing that is.
  """
  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Users.Referrals
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, session, socket) do
    user = socket.assigns[:phoenix_kit_current_user]
    destination = Routes.post_auth_path([params["return_to"], session["user_return_to"]])

    cond do
      is_nil(user) ->
        # Nothing to admit. Sending them to log-in rather than rendering an
        # empty form avoids a page that asks an anonymous visitor for a code
        # and then has nowhere to put it.
        {:ok, redirect(socket, to: Routes.path("/users/log-in"))}

      # The scope is already mounted, so pass it rather than the bare user —
      # the user form would have to rebuild it to evaluate the full-access
      # exemption.
      Referrals.access_satisfied?(socket.assigns[:phoenix_kit_current_scope]) ->
        # Already admitted — covers a code redeemed in another tab, an
        # invitation that arrived while this page sat open, and an operator
        # switching invite-only off.
        {:ok, redirect(socket, to: destination)}

      true ->
        {:ok,
         socket
         |> assign(:page_title, gettext("Enter your referral code"))
         |> assign(:destination, destination)
         |> assign(:error, nil)
         |> assign(:ip_address, IpAddress.extract_from_socket(socket))
         |> assign(:form, to_form(%{"code" => ""}, as: "referral"))}
    end
  end

  @impl true
  def handle_event("redeem", %{"referral" => %{"code" => code}}, socket) do
    user = socket.assigns.phoenix_kit_current_user

    with :ok <- RateLimiter.check_referral_redemption_rate_limit(user.uuid),
         {:ok, %{} = validated} <- validate(code, socket) do
      admit(socket, user, validated)
    else
      {:error, :rate_limit_exceeded} ->
        {:noreply, reject(socket, code, gettext("Too many attempts. Please try again shortly."))}

      # A blank submission, or an enabled-but-not-required config. Neither can
      # admit anyone, so both read as a plain rejection rather than falling
      # through to `admit/3` with nothing to record.
      {:ok, nil} ->
        {:noreply, reject(socket, code, gettext("That code can't be used"))}

      {:error, message} ->
        {:noreply, reject(socket, code, message)}
    end
  end

  defp validate(code, socket) do
    Referrals.validate_for_signup(code,
      enabled?: true,
      required?: true,
      context: :submit,
      ip_address: socket.assigns.ip_address
    )
  end

  defp admit(socket, user, validated_code) do
    Referrals.use_code(validated_code.code, user.uuid)

    case Referrals.mark_satisfied(user, "code") do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Welcome! Your referral code has been accepted."))
         |> redirect(to: socket.assigns.destination)}

      {:error, reason} ->
        # The code was consumed but the mark did not stick, so letting them
        # through would be a lie the next request undoes. Say so plainly
        # instead of showing the generic rejection — this is our fault, not a
        # bad code, and the operator needs it in the log.
        Logger.error("[ReferralGate] could not mark #{user.uuid} satisfied: #{inspect(reason)}")

        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Something went wrong on our end. Please try again.")
         )}
    end
  end

  defp reject(socket, code, message) do
    socket
    |> assign(:error, message)
    |> assign(:form, to_form(%{"code" => code}, as: "referral"))
  end
end
