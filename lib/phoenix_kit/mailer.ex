defmodule PhoenixKit.Mailer do
  @moduledoc """
  Mailer module for PhoenixKit authentication emails.

  This module handles sending authentication-related emails such as
  confirmation emails, password reset emails, magic link emails, etc.
  """

  use Swoosh.Mailer, otp_app: :phoenix_kit

  import Swoosh.Email

  alias PhoenixKit.Users.Auth.User

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

    deliver(email)
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

  # Get the from email address from configuration or use a default
  defp get_from_email do
    case PhoenixKit.Config.get(:from_email) do
      {:ok, email} -> email
      :not_found -> "noreply@localhost"
    end
  end
end
