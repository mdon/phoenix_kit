defmodule PhoenixKit.Notifications.Channels.Email do
  @moduledoc """
  Email notification channel — delivers a user's notifications to their account
  email address via `PhoenixKit.Mailer`.

  Unlike Telegram, email needs **no setup**: every user has an account email, so
  `configured?/2` is always true and the Email column is available from the
  start. There's no per-user connection or config beyond the routing/cadence the
  matrix + aggregation popup write.
  """

  @behaviour PhoenixKit.Notifications.Channel

  use Gettext, backend: PhoenixKitWeb.Gettext

  import Swoosh.Email

  alias PhoenixKit.Mailer
  alias PhoenixKit.Users.Auth

  @impl true
  def key, do: "email"

  @impl true
  def label, do: gettext("Email")

  @impl true
  def icon, do: "hero-envelope"

  # Always available — nothing to connect. (A user with no address can't be
  # reached, but that's a delivery-time miss, not a configuration state.)
  @impl true
  def configured?(_user_uuid, _config), do: true

  @impl true
  def deliver(envelope, _config) do
    case Auth.get_user(envelope.recipient_uuid) do
      %{email: address} when is_binary(address) and address != "" ->
        send_email(address, envelope)

      _ ->
        {:error, {:permanent, :no_recipient_email}}
    end
  end

  @impl true
  def validate_config(config) when is_map(config), do: {:ok, config}

  # --- Internals ------------------------------------------------------------

  defp send_email(address, envelope) do
    email =
      new()
      |> to(address)
      |> from({Mailer.get_from_name(), Mailer.get_from_email()})
      |> subject(subject_for(envelope))
      |> text_body(body_for(envelope))

    case Mailer.deliver_email(email, category: "notifications") do
      {:ok, _} -> :ok
      # A blocklisted recipient (hard bounce / complaint) won't recover on retry.
      {:error, {:blocked, reason}} -> {:error, {:permanent, reason}}
      {:error, reason} -> {:error, {:transient, reason}}
    end
  end

  defp subject_for(%{title: title}) when is_binary(title) and title != "", do: title
  defp subject_for(%{text: text}), do: String.slice(text, 0, 120)

  defp body_for(%{text: text, url: url}) when is_binary(url) and url != "",
    do: "#{text}\n\n#{url}"

  defp body_for(%{text: text}), do: text
end
