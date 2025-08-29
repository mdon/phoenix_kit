defmodule PhoenixKit.Install.MailerConfig do
  @moduledoc """
  Handles mailer configuration for PhoenixKit installation.

  This module provides functionality to:
  - Configure development mailer with Swoosh.Adapters.Local
  - Add production mailer templates for various providers
  - Generate appropriate notices for mailer setup
  """

  alias Igniter.Project.Config

  @doc """
  Adds PhoenixKit mailer configuration for development and production.

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with mailer configuration and notices.
  """
  def add_mailer_configuration(igniter) do
    igniter
    |> add_dev_mailer_config()
    |> add_prod_mailer_config()
    |> add_mailer_production_notice()
  end

  # Add Local mailer adapter for development
  defp add_dev_mailer_config(igniter) do
    Config.configure_new(
      igniter,
      "dev.exs",
      :phoenix_kit,
      [PhoenixKit.Mailer],
      adapter: Swoosh.Adapters.Local
    )
  end

  # Add production mailer configuration template as comments
  defp add_prod_mailer_config(igniter) do
    prod_config_template = get_prod_mailer_template()

    if File.exists?("config/prod.exs") do
      # Check if PhoenixKit mailer config already exists before appending
      Igniter.update_file(igniter, "config/prod.exs", fn source ->
        try do
          current_content = Rewrite.Source.get(source, :content)

          # Only add template if PhoenixKit mailer config doesn't already exist
          if String.contains?(current_content, "# Configure PhoenixKit mailer for production") do
            # Config already exists, no changes needed
            source
          else
            # Add the template
            updated_content = current_content <> "\n" <> prod_config_template
            Rewrite.Source.update(source, :content, updated_content)
          end
        rescue
          _ ->
            # Fallback: just return original source if there's an error
            source
        end
      end)
    else
      # Create prod.exs with import Config and template
      initial_content = "import Config\n" <> prod_config_template
      Igniter.create_new_file(igniter, "config/prod.exs", initial_content)
    end
  end

  # Get production mailer configuration template
  defp get_prod_mailer_template do
    """
    # Configure PhoenixKit mailer for production
    # Uncomment and configure the adapter you want to use:

    # SMTP configuration (recommended for most providers)
    # config :phoenix_kit, PhoenixKit.Mailer,
    #   adapter: Swoosh.Adapters.SMTP,
    #   relay: "smtp.sendgrid.net",
    #   username: System.get_env("SENDGRID_USERNAME"),
    #   password: System.get_env("SENDGRID_PASSWORD"),
    #   port: 587,
    #   auth: :always,
    #   tls: :always

    # SendGrid API configuration
    # config :phoenix_kit, PhoenixKit.Mailer,
    #   adapter: Swoosh.Adapters.Sendgrid,
    #   api_key: System.get_env("SENDGRID_API_KEY")

    # Mailgun configuration
    # config :phoenix_kit, PhoenixKit.Mailer,
    #   adapter: Swoosh.Adapters.Mailgun,
    #   api_key: System.get_env("MAILGUN_API_KEY"),
    #   domain: System.get_env("MAILGUN_DOMAIN")

    # Amazon SES configuration
    # config :phoenix_kit, PhoenixKit.Mailer,
    #   adapter: Swoosh.Adapters.AmazonSES,
    #   region: "us-east-1",
    #   access_key: System.get_env("AWS_ACCESS_KEY_ID"),
    #   secret: System.get_env("AWS_SECRET_ACCESS_KEY")

    """
  end

  # Add brief notice about mailer configuration
  defp add_mailer_production_notice(igniter) do
    notice = """

    📧 Development mailer configured (Swoosh.Adapters.Local)
    📄 Production mailer templates added to config/prod.exs (as comments)
    💡 Uncomment and configure your preferred email provider
    """

    Igniter.add_notice(igniter, notice)
  end
end
