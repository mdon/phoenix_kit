defmodule PhoenixKit.Users.Auth.UserNotifier do
  @moduledoc """
  User notification system for PhoenixKit authentication workflows.

  This module handles email delivery for user authentication and account management workflows,
  including account confirmation, password reset, and email change notifications.

  ## Email Types

  - **Confirmation instructions**: Sent during user registration
  - **Password reset instructions**: Sent when user requests password reset
  - **Email update instructions**: Sent when user changes their email address

  ## Configuration

  Configure your mailer in your application config:

      config :phoenix_kit, PhoenixKit.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        # ... other adapter configuration

  ## Customization

  Override this module in your application to customize email templates
  and delivery behavior while maintaining the same function signatures.
  """
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Swoosh.Email

  alias PhoenixKit.Email.Content
  alias PhoenixKit.Email.Provider
  alias PhoenixKit.Mailer
  alias PhoenixKit.Utils.Routes

  # Every templated auth email resolves identically and differs only in its
  # name, its variables and its default copy — so the resolution, the usage
  # tracking and the send live here once instead of five times.
  #
  # `recipient` is what the locale is resolved from (a user struct, or a bare
  # address where no account exists yet); `address` is who it is sent to. They
  # differ only on the magic-link registration path.
  defp deliver_templated(recipient, address, name, variables, defaults) do
    content = Content.resolve(name, recipient, variables, defaults)

    if content.db_template, do: Provider.current().track_usage(content.db_template)

    deliver(address, content.subject, content.text, content.html)
  end

  # Delivers the email using the appropriate mailer.
  # Uses the configured parent application mailer if available,
  # otherwise falls back to PhoenixKit's built-in mailer.
  defp deliver(recipient, subject, text_body, html_body) do
    from_email = get_from_email()
    from_name = get_from_name()

    email =
      new()
      |> to(recipient)
      |> from({from_name, from_email})
      |> subject(subject)
      |> text_body(text_body)
      |> html_body(html_body)

    with {:ok, _metadata} <-
           Mailer.deliver_email(email,
             user_uuid: nil,
             template_name: "user_notification",
             campaign_id: "authentication"
           ) do
      {:ok, email}
    end
  end

  # Get the from email address from configuration or use a default
  # Priority: Settings Database > Config file > Default
  defp get_from_email do
    # Priority 1: Settings Database (runtime)
    case PhoenixKit.Settings.get_setting("from_email") do
      nil ->
        # Priority 2: Config file (compile-time, fallback)
        case PhoenixKit.Config.get(:from_email) do
          {:ok, email} -> email
          # Priority 3: Default
          _ -> "noreply@localhost"
        end

      email ->
        email
    end
  end

  # Get the from name from configuration or use a default
  # Priority: Settings Database > Config file > Default
  defp get_from_name do
    # Priority 1: Settings Database (runtime)
    case PhoenixKit.Settings.get_setting("from_name") do
      nil ->
        # Priority 2: Config file (compile-time, fallback)
        case PhoenixKit.Config.get(:from_name) do
          {:ok, name} -> name
          # Priority 3: Default
          _ -> "PhoenixKit"
        end

      name ->
        name
    end
  end

  @doc """
  Deliver instructions to confirm account.
  """
  def deliver_confirmation_instructions(user, url) do
    deliver_templated(
      user,
      user.email,
      "register",
      %{"user_email" => user.email, "confirmation_url" => url},
      fn ->
        %{
          subject: gettext("Confirm your account"),
          text:
            gettext("""
            Hi {{user_email}},

            You can confirm your account by visiting the URL below:

            {{confirmation_url}}

            If you didn't create an account with us, please ignore this.
            """)
        }
      end
    )
  end

  @doc """
  Deliver instructions to reset a user password.
  """
  def deliver_reset_password_instructions(user, url) do
    deliver_templated(
      user,
      user.email,
      "reset_password",
      %{"user_email" => user.email, "reset_url" => url},
      fn ->
        %{
          subject: gettext("Reset your password"),
          text:
            gettext("""
            Hi {{user_email}},

            You can reset your password by visiting the URL below:

            {{reset_url}}

            If you didn't request this change, please ignore this.
            """)
        }
      end
    )
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver_templated(
      user,
      user.email,
      "update_email",
      %{"user_email" => user.email, "update_url" => url},
      fn ->
        %{
          subject: gettext("Confirm your email change"),
          text:
            gettext("""
            Hi {{user_email}},

            You can change your email by visiting the URL below:

            {{update_url}}

            If you didn't request this change, please ignore this.
            """)
        }
      end
    )
  end

  @doc """
  Deliver organization invitation email to a new (unregistered) user.

  Sends a registration link containing the invitation token so the invitee
  can register and automatically join the organization on email confirmation.
  """
  def deliver_organization_invitation(email, organization_name, registration_url) do
    deliver_templated(
      email,
      email,
      "organization_invitation",
      %{
        "user_email" => email,
        "organization_name" => organization_name,
        "registration_url" => registration_url
      },
      fn ->
        %{
          subject: gettext("You've been invited to join {{organization_name}}"),
          text:
            gettext("""
            Hi {{user_email}},

            {{organization_name}} has invited you to join their organization.

            To accept the invitation, register an account by visiting the link below:

            {{registration_url}}

            This invitation link will expire in 7 days.

            If you did not expect this invitation, you can safely ignore this email.
            """)
        }
      end
    )
  end

  @doc """
  Deliver magic link registration instructions.

  Accepts a user struct or a bare address: on this path the account does not
  exist yet, so there may be no stored locale preference to resolve.
  """
  def deliver_magic_link_registration(user_or_email, url) do
    email =
      case user_or_email do
        %{email: email} -> email
        email when is_binary(email) -> email
      end

    deliver_templated(
      user_or_email,
      email,
      "magic_link_registration",
      %{"user_email" => email, "registration_url" => url},
      fn ->
        %{
          subject: gettext("Complete your registration"),
          text:
            gettext("""
            Hi {{user_email}},

            Welcome! To complete your registration, please visit the URL below:

            {{registration_url}}

            This link will expire in 30 minutes for your security.

            If you didn't request this registration, please ignore this email.
            """)
        }
      end
    )
  end

  @doc """
  Deliver a "new login detected" security alert.

  Sent by `PhoenixKit.Users.LoginAlerts` when a login is seen from a
  device (IP + user-agent pair) not previously associated with the
  account. `attrs` carries `:ip_address`, `:browser`, `:os` (either may be
  `nil`), `:location` (a "City, Country" string, or `nil` if geolocation
  didn't resolve), and `:first_seen_at` (a `DateTime`).
  """
  def deliver_new_login_alert(user, attrs) do
    browser_os = [attrs[:browser], attrs[:os]] |> Enum.filter(& &1) |> Enum.join(" on ")

    variables = %{
      "user_email" => user.email,
      "login_time" => Calendar.strftime(attrs.first_seen_at, "%Y-%m-%d %H:%M UTC"),
      "ip_address" => attrs.ip_address,
      "location" => attrs[:location] || gettext("Unknown"),
      "browser_os" => (browser_os == "" && gettext("Unknown")) || browser_os,
      # The one email that reaches a genuinely compromised account was, until
      # now, the one with no way to act on it: it said "change your password
      # immediately" and gave the reader nothing to click.
      "security_url" => Routes.base_url() <> Routes.user_settings_path()
    }

    deliver_templated(user, user.email, "new_login_alert", variables, fn ->
      %{
        subject: gettext("New login to your account"),
        text:
          gettext("""
          Hi {{user_email}},

          We noticed a new login to your account:

          Time: {{login_time}}
          IP address: {{ip_address}}
          Location: {{location}}
          Device: {{browser_os}}

          If this was you, no action is needed.

          If you don't recognize this activity, secure your account here:

          {{security_url}}
          """)
      }
    end)
  end
end
