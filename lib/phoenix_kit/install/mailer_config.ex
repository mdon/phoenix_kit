defmodule PhoenixKit.Install.MailerConfig do
  use PhoenixKit.Install.IgniterCompat

  @moduledoc """
  Handles mailer configuration for PhoenixKit installation.

  This module provides functionality to:
  - Configure development mailer with Swoosh.Adapters.Local
  - Add production mailer templates for various providers
  - Generate appropriate notices for mailer setup
  """

  alias Igniter.Project.Config
  alias PhoenixKit.Install.FinchSetup
  alias PhoenixKit.Install.RuntimeDetector

  @doc """
  Adds PhoenixKit mailer configuration for development and production.

  Now supports both delegation mode and built-in mode:
  - **Delegation mode**: Configure PhoenixKit to use parent app's mailer
  - **Built-in mode**: Configure PhoenixKit's own mailer (legacy)

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with mailer configuration and notices.
  """
  def add_mailer_configuration(igniter) do
    igniter
    |> add_mailer_delegation_config()
    |> add_prod_mailer_config()
    |> FinchSetup.add_finch_configuration()
    |> add_mailer_production_notice()
  end

  # Add mailer delegation configuration - detects and uses parent app's mailer
  defp add_mailer_delegation_config(igniter) do
    parent_app = get_parent_app_name()

    case detect_parent_mailer(parent_app) do
      {:ok, parent_mailer} ->
        # Configure PhoenixKit to use parent app's mailer
        Config.configure_new(
          igniter,
          "config.exs",
          :phoenix_kit,
          [:mailer],
          parent_mailer
        )

      :not_found ->
        # Fall back to built-in PhoenixKit mailer
        add_dev_mailer_config(igniter)
    end
  end

  # Add Local mailer adapter for development - supports both dev.exs and runtime.exs
  defp add_dev_mailer_config(igniter) do
    case RuntimeDetector.detect_config_pattern() do
      :runtime ->
        add_runtime_mailer_config(igniter)

      :dev_exs ->
        add_simple_dev_mailer_config(igniter)

      :config_exs ->
        add_config_exs_mailer_config(igniter)
    end
  end

  # Add mailer config to runtime.exs file
  defp add_runtime_mailer_config(igniter) do
    case RuntimeDetector.find_insertion_point() do
      {:runtime, line_number} ->
        insert_into_runtime_file(igniter, line_number)

      {:dev_exs, line_number} ->
        add_simple_dev_mailer_config_at_line(igniter, line_number)

      {:config_exs, line_number} ->
        add_config_exs_mailer_config_at_line(igniter, line_number)
    end
  end

  # Simple dev.exs configuration (legacy behavior)
  defp add_simple_dev_mailer_config(igniter) do
    Config.configure_new(
      igniter,
      "dev.exs",
      :phoenix_kit,
      [PhoenixKit.Mailer],
      adapter: Swoosh.Adapters.Local
    )
  end

  # Add mailer config to config.exs with environment check
  defp add_config_exs_mailer_config(igniter) do
    config_content = """
    # PhoenixKit mailer configuration
    if config_env() == :dev do
      config :phoenix_kit, PhoenixKit.Mailer,
        adapter: Swoosh.Adapters.Local
    end
    """

    # Try to append to config.exs, fall back to notice if it fails
    try do
      Igniter.update_file(igniter, "config/config.exs", fn source ->
        current_content = Rewrite.Source.get(source, :content)
        updated_content = current_content <> "\n" <> config_content
        Rewrite.Source.update(source, :content, updated_content)
      end)
    rescue
      _ ->
        add_runtime_config_notice(igniter)
    end
  end

  # Insert mailer config into runtime.exs file
  defp insert_into_runtime_file(igniter, line_number) do
    mailer_config = """
      # PhoenixKit mailer configuration
      config :phoenix_kit, PhoenixKit.Mailer,
        adapter: Swoosh.Adapters.Local
    """

    try do
      Igniter.update_file(igniter, "config/runtime.exs", fn source ->
        current_content = Rewrite.Source.get(source, :content)
        lines = String.split(current_content, "\n")

        # Insert at the specified line
        {before_lines, after_lines} = Enum.split(lines, line_number - 1)

        updated_content =
          (before_lines ++
             [mailer_config] ++
             after_lines)
          |> Enum.join("\n")

        Rewrite.Source.update(source, :content, updated_content)
      end)
    rescue
      _ ->
        # Fallback to simple notice if insertion fails
        add_runtime_config_notice(igniter)
    end
  end

  # Add dev mailer config at specific line number
  defp add_simple_dev_mailer_config_at_line(igniter, line_number) do
    mailer_config = """
    # PhoenixKit mailer configuration
    config :phoenix_kit, PhoenixKit.Mailer,
      adapter: Swoosh.Adapters.Local
    """

    try do
      Igniter.update_file(igniter, "config/dev.exs", fn source ->
        current_content = Rewrite.Source.get(source, :content)
        lines = String.split(current_content, "\n")

        # Insert at the specified line
        {before_lines, after_lines} = Enum.split(lines, line_number - 1)

        updated_content =
          (before_lines ++
             [mailer_config] ++
             after_lines)
          |> Enum.join("\n")

        Rewrite.Source.update(source, :content, updated_content)
      end)
    rescue
      _ ->
        # Fallback to default behavior
        add_simple_dev_mailer_config(igniter)
    end
  end

  # Add config_exs mailer config at specific line number
  defp add_config_exs_mailer_config_at_line(igniter, line_number) do
    mailer_config = """
    # PhoenixKit mailer configuration
    if config_env() == :dev do
      config :phoenix_kit, PhoenixKit.Mailer,
        adapter: Swoosh.Adapters.Local
    end
    """

    try do
      Igniter.update_file(igniter, "config/config.exs", fn source ->
        current_content = Rewrite.Source.get(source, :content)
        lines = String.split(current_content, "\n")

        # Insert at the specified line
        {before_lines, after_lines} = Enum.split(lines, line_number - 1)

        updated_content =
          (before_lines ++
             [mailer_config] ++
             after_lines)
          |> Enum.join("\n")

        Rewrite.Source.update(source, :content, updated_content)
      end)
    rescue
      _ ->
        # Fallback to notice
        add_runtime_config_notice(igniter)
    end
  end

  # Get the parent application name
  defp get_parent_app_name do
    Mix.Project.config()[:app]
  end

  # Detect parent application's mailer module
  defp detect_parent_mailer(app_name) do
    app_module = app_name |> to_string() |> Macro.camelize()

    # Common mailer module patterns
    mailer_candidates = [
      Module.concat([app_module, "Mailer"]),
      Module.concat([app_module <> "Web", "Mailer"])
    ]

    # Find the first existing mailer module
    mailer_candidates
    |> Enum.find(&mailer_module_exists?/1)
    |> case do
      nil -> :not_found
      mailer -> {:ok, mailer}
    end
  end

  # Check if a mailer module exists in the project
  defp mailer_module_exists?(module) do
    case Code.ensure_compiled(module) do
      {:module, _} -> function_exported?(module, :deliver, 1)
      _ -> false
    end
  rescue
    _ -> false
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
    # 
    # IMPORTANT: Configure sender email address
    # config :phoenix_kit,
    #   from_email: "noreply@yourcompany.com",
    #   from_name: "Your Company Name"

    # OPTION 1 (RECOMMENDED): Use your app's existing mailer
    # PhoenixKit will automatically use your app's mailer if configured with:
    # config :phoenix_kit, mailer: MyApp.Mailer
    #
    # Then configure your app's mailer as usual:
    # config :my_app, MyApp.Mailer,
    #   adapter: Swoosh.Adapters.SMTP,
    #   relay: "smtp.sendgrid.net",
    #   username: System.get_env("SENDGRID_USERNAME"),
    #   password: System.get_env("SENDGRID_PASSWORD"),
    #   port: 587,
    #   auth: :always,
    #   tls: :always

    # OPTION 2 (LEGACY): Configure PhoenixKit's built-in mailer
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

    # ==========================================
    # Amazon SES configuration (COMPLETE SETUP GUIDE)
    # ==========================================

    # STEP 1: Add required dependencies to mix.exs
    # {:gen_smtp, "~> 1.2"}  # Required for AWS SES
    # {:finch, "~> 0.18"}    # Required for HTTP client
    #
    # Also add :finch to extra_applications in mix.exs:
    # extra_applications: [:logger, :runtime_tools, :finch]

    # STEP 2: Add Finch to your application supervisor (lib/your_app/application.ex)
    # Add this to your children list:
    # {Finch, name: Swoosh.Finch}

    # STEP 3: Configure Swoosh API client (config/config.exs)
    # config :swoosh, :api_client, Swoosh.ApiClient.Finch
    #
    # ⚠️ IMPORTANT: Check that config/dev.exs does NOT have:
    # config :swoosh, :api_client, false
    # This setting will override Finch configuration and break AWS SES!

    # STEP 4: Configure AWS SES
    # For your app's mailer (recommended approach):
    # config :your_app, YourApp.Mailer,
    #   adapter: Swoosh.Adapters.AmazonSES,
    #   region: "eu-north-1",  # or "us-east-1", "us-west-2", etc.
    #   access_key: System.get_env("AWS_ACCESS_KEY_ID"),
    #   secret: System.get_env("AWS_SECRET_ACCESS_KEY")
    #
    # Then configure PhoenixKit to use your mailer:
    # config :phoenix_kit,
    #   mailer: YourApp.Mailer,
    #   from_email: "noreply@yourcompany.com",
    #   from_name: "Your Company"
    #
    # Legacy approach (using PhoenixKit's built-in mailer):
    # config :phoenix_kit, PhoenixKit.Mailer,
    #   adapter: Swoosh.Adapters.AmazonSES,
    #   region: "eu-north-1",
    #   access_key: System.get_env("AWS_ACCESS_KEY_ID"),
    #   secret: System.get_env("AWS_SECRET_ACCESS_KEY")

    # STEP 5: AWS SES Setup Checklist
    # □ Create AWS IAM user with SES permissions (ses:*)
    # □ Verify sender email address in AWS SES Console  
    # □ Verify recipient email addresses (if in sandbox mode)
    # □ Ensure correct AWS region matches your verification
    # □ Request production access to send to any email
    # □ Set environment variables:
    #   - AWS_ACCESS_KEY_ID
    #   - AWS_SECRET_ACCESS_KEY
    #   - AWS_REGION (optional, defaults to eu-north-1)

    # Common AWS SES regions:
    # - eu-west-1 (Ireland)
    # - us-east-1 (N. Virginia)
    # - us-west-2 (Oregon)  
    # - eu-north-1 (Stockholm)


    # TROUBLESHOOTING:
    # If you see "function false.post/4 is undefined":
    # 1. Check that Finch is in your mix.exs deps: {:finch, "~> 0.18"}
    # 2. Check that :finch is in extra_applications
    # 3. Check that Swoosh.Finch is in application.ex children
    # 4. Make sure there's no "api_client: false" in dev.exs
    # 5. Restart your Phoenix server after changes
    #
    # See full setup guide: docs/AWS_SES_SETUP.md

    """
  end

  # Add brief notice about mailer configuration
  defp add_mailer_production_notice(igniter) do
    parent_app = get_parent_app_name()

    notice =
      case detect_parent_mailer(parent_app) do
        {:ok, parent_mailer} ->
          "📧 Email configured to use #{inspect(parent_mailer)} (see config/prod.exs for production setup)"

        :not_found ->
          "📧 Email configured (built-in PhoenixKit.Mailer, see config/prod.exs)"
      end

    Igniter.add_notice(igniter, notice)
  end

  # Add notice when runtime configuration cannot be automatically applied
  defp add_runtime_config_notice(igniter) do
    notice = """
    ⚠️  Runtime configuration detected
    PhoenixKit couldn't automatically configure the mailer due to complex runtime.exs patterns.

    Please add this configuration manually to your runtime.exs dev block:

    config :phoenix_kit, PhoenixKit.Mailer,
      adapter: Swoosh.Adapters.Local
    """

    Igniter.add_notice(igniter, notice)
  end
end
