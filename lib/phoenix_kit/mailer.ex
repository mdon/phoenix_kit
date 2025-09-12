defmodule PhoenixKit.Mailer do
  @moduledoc """
  Mailer module for PhoenixKit emails.

  This module handles sending emails such as
  confirmation emails, password reset emails, magic link emails, etc.

  It can work in two modes:
  1. **Built-in mode**: Uses PhoenixKit's own Swoosh mailer (default)
  2. **Delegation mode**: Uses the parent application's mailer when configured

  ## Configuration

  To use your application's mailer instead of PhoenixKit's built-in one:

      config :phoenix_kit,
        mailer: MyApp.Mailer

  When delegation is configured, all emails will be sent through your application's 
  mailer, allowing you to use a single mailer configuration across your entire application.
  """

  use Swoosh.Mailer, otp_app: :phoenix_kit

  import Swoosh.Email

  alias PhoenixKit.EmailTracking.EmailInterceptor

  alias PhoenixKit.Users.Auth.User

  @doc """
  Gets the mailer module to use for sending emails.

  Returns the configured parent application mailer if set,
  otherwise returns the built-in PhoenixKit.Mailer.

  ## Examples

      iex> PhoenixKit.Mailer.get_mailer()
      MyApp.Mailer  # if configured
      
      iex> PhoenixKit.Mailer.get_mailer()
      PhoenixKit.Mailer  # default
  """
  def get_mailer do
    PhoenixKit.Config.get(:mailer, __MODULE__)
  end

  @doc """
  Delivers an email using the appropriate mailer.

  If a parent application mailer is configured, delegates to it.
  Otherwise uses the built-in PhoenixKit mailer.

  This function also integrates with the email tracking system to log
  outgoing emails when tracking is enabled.
  """
  def deliver_email(email, opts \\ []) do
    # Intercept email for tracking before sending
    tracked_email = EmailInterceptor.intercept_before_send(email, opts)

    mailer = get_mailer()

    result =
      if mailer == __MODULE__ do
        # Use built-in mailer
        __MODULE__.deliver(tracked_email)
      else
        # Delegate to parent application mailer
        mailer.deliver(tracked_email)
      end

    # Handle post-send tracking updates
    handle_delivery_result(tracked_email, result, opts)

    result
  end

  @doc """
  Sends a magic link email to the user.

  ## Examples

      iex> PhoenixKit.Mailer.send_magic_link_email(user, "https://app.com/magic/token123")
      {:ok, %Swoosh.Email{}}
  """
  def send_magic_link_email(%User{} = user, magic_link_url) when is_binary(magic_link_url) do
    email =
      new()
      |> to({user.email, user.email})
      |> from({"PhoenixKit", get_from_email()})
      |> subject("Your secure login link")
      |> html_body(magic_link_html_body(user, magic_link_url))
      |> text_body(magic_link_text_body(user, magic_link_url))

    deliver_email(email,
      user_id: user.id,
      template_name: "magic_link",
      campaign_id: "authentication",
      provider: detect_provider()
    )
  end

  # HTML version of the magic link email
  defp magic_link_html_body(%User{} = user, magic_link_url) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Your Secure Login Link</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; }
        .container { max-width: 600px; margin: 0 auto; padding: 20px; }
        .header { text-align: center; margin-bottom: 30px; }
        .button { display: inline-block; padding: 12px 24px; background-color: #3b82f6; color: white; text-decoration: none; border-radius: 6px; font-weight: 500; }
        .button:hover { background-color: #2563eb; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #e5e7eb; font-size: 14px; color: #6b7280; }
        .warning { background-color: #fef3c7; border: 1px solid #f59e0b; border-radius: 6px; padding: 16px; margin: 20px 0; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>Secure Login Link</h1>
        </div>

        <p>Hi #{user.email},</p>

        <p>Click the button below to securely log in to your account:</p>

        <p style="text-align: center; margin: 30px 0;">
          <a href="#{magic_link_url}" class="button">Log In Securely</a>
        </p>

        <div class="warning">
          <strong>⚠️ Important:</strong> This link will expire in 15 minutes and can only be used once.
        </div>

        <p>If you didn't request this login link, you can safely ignore this email.</p>

        <p>For your security, never share this link with anyone.</p>

        <div class="footer">
          <p>If the button above doesn't work, you can copy and paste this link into your browser:</p>
          <p><a href="#{magic_link_url}">#{magic_link_url}</a></p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  # Text version of the magic link email
  defp magic_link_text_body(%User{} = user, magic_link_url) do
    """
    Secure Login Link

    Hi #{user.email},

    Click the link below to securely log in to your account:

    #{magic_link_url}

    ⚠️ Important: This link will expire in 15 minutes and can only be used once.

    If you didn't request this login link, you can safely ignore this email.

    For your security, never share this link with anyone.
    """
  end

  # Handle delivery result for email tracking updates
  defp handle_delivery_result(email, result, opts) do
    # Only process if email tracking is enabled
    if PhoenixKit.EmailTracking.enabled?() do
      case extract_log_id_from_email(email) do
        nil ->
          # No log ID found, skip tracking
          :ok

        log_id ->
          case PhoenixKit.EmailTracking.get_log!(log_id) do
            nil -> :ok
            log -> update_log_after_delivery(log, result, opts)
          end
      end
    end
  rescue
    # Don't fail email delivery if tracking update fails
    error ->
      require Logger
      Logger.error("Failed to update email tracking after delivery: #{inspect(error)}")
      :ok
  end

  # Extract log ID from email headers
  defp extract_log_id_from_email(email) do
    case get_in(email.headers, ["X-PhoenixKit-Log-Id"]) do
      nil ->
        nil

      log_id_str ->
        case Integer.parse(log_id_str) do
          {log_id, _} -> log_id
          _ -> nil
        end
    end
  end

  # Update email log based on delivery result
  defp update_log_after_delivery(log, {:ok, response}, _opts) do
    EmailInterceptor.update_after_send(log, response)
  end

  defp update_log_after_delivery(log, {:error, error}, _opts) do
    EmailInterceptor.update_after_failure(log, error)
  end

  defp update_log_after_delivery(_log, _result, _opts) do
    # Unknown result format, skip update
    :ok
  end

  # Detect current email provider from configuration
  defp detect_provider do
    mailer = get_mailer()

    if mailer == __MODULE__ do
      # Using built-in PhoenixKit mailer, check its configuration
      config = Application.get_env(:phoenix_kit, __MODULE__, [])
      adapter = Keyword.get(config, :adapter)

      case adapter do
        Swoosh.Adapters.AmazonSES -> "aws_ses"
        Swoosh.Adapters.SMTP -> "smtp"
        Swoosh.Adapters.Sendgrid -> "sendgrid"
        Swoosh.Adapters.Mailgun -> "mailgun"
        Swoosh.Adapters.Local -> "local"
        _ -> "phoenix_kit_builtin"
      end
    else
      # Using parent application mailer, try to detect its adapter
      case mailer do
        module when is_atom(module) ->
          app = PhoenixKit.Config.get_parent_app()
          config = Application.get_env(app, module, [])
          adapter = Keyword.get(config, :adapter)

          case adapter do
            Swoosh.Adapters.AmazonSES -> "aws_ses"
            Swoosh.Adapters.SMTP -> "smtp"
            Swoosh.Adapters.Sendgrid -> "sendgrid"
            Swoosh.Adapters.Mailgun -> "mailgun"
            Swoosh.Adapters.Local -> "local"
            _ -> "parent_app_mailer"
          end

        _ ->
          "unknown"
      end
    end
  end

  # Get the from email address from configuration or use a default
  defp get_from_email do
    case PhoenixKit.Config.get(:from_email) do
      {:ok, email} -> email
      :not_found -> "noreply@localhost"
    end
  end
end
