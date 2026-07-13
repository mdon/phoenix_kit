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

  alias PhoenixKit.Email.Provider
  alias PhoenixKit.Integrations
  alias PhoenixKit.Users.Auth.User

  require Logger

  # Soft dependency: the optional `emails` package (not a dependency of
  # core) owns the recipient blocklist (hard bounces, spam complaints,
  # manual blocks). Referencing it as a bare module name costs nothing at
  # compile time; `check_recipient_allowed/1` below guards every call with
  # `Code.ensure_loaded?/1`, so this file has no hard dependency on the
  # optional package and every recipient is implicitly allowed when it
  # isn't installed.
  #
  # We deliberately call `check_blocklist/1`, NOT `check_limits/1`:
  # `check_limits/1` additionally enforces the emails module's per-recipient
  # (100/h) and GLOBAL (10_000/h) send caps, which are not gated by any
  # enable flag. Wiring those in here would silently throttle every outbound
  # email app-wide (auth mail included) and would cap bulk newsletter
  # broadcasts at 10k/hour. Send pacing/quotas belong to the newsletters
  # send-profile limits (roadmap Phase 5, per-profile atomic caps) — one
  # limiter, not two competing ones.
  @emails_rate_limiter PhoenixKit.Modules.Emails.RateLimiter

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
  Sends an email using a template from the database.

  This is the main function for sending emails using PhoenixKit's template system.
  It automatically:
  - Loads the template by name
  - Renders it with provided variables
  - Tracks template usage
  - Sends the email with tracking
  - Logs to EmailSystem

  ## Parameters

  - `template_name` - Name of the template in the database (e.g., "welcome_email")
  - `recipient` - Email address (string) or {name, email} tuple
  - `variables` - Map of variables to substitute in the template
  - `opts` - Additional options:
    - `:user_uuid` - Associate email with a user (for tracking)
    - `:campaign_id` - Campaign identifier (for analytics)
    - `:from` - Override from address (default: configured from_email)
    - `:reply_to` - Reply-to address
    - `:metadata` - Additional metadata map for tracking

  ## Returns

  - `{:ok, email}` - Email sent successfully
  - `{:error, :template_not_found}` - Template doesn't exist
  - `{:error, :template_inactive}` - Template is not active
  - `{:error, reason}` - Other error

  ## Examples

      # Simple welcome email
      PhoenixKit.Mailer.send_from_template(
        "welcome_email",
        "user@example.com",
        %{"user_name" => "John", "url" => "https://app.com"}
      )

      # With user tracking
      PhoenixKit.Mailer.send_from_template(
        "password_reset",
        {"Jane Doe", "jane@example.com"},
        %{"reset_url" => "https://app.com/reset/token123"},
        user_uuid: user.uuid,
        campaign_id: "password_recovery"
      )

      # With metadata
      PhoenixKit.Mailer.send_from_template(
        "order_confirmation",
        customer.email,
        %{"order_id" => "12345", "total" => "$99.99"},
        user_uuid: customer.uuid,
        campaign_id: "orders",
        metadata: %{order_id: order.id, amount: order.total}
      )
  """
  def send_from_template(template_name, recipient, variables \\ %{}, opts \\ [])
      when is_binary(template_name) do
    # Get the template from database
    case Provider.current().get_active_template_by_name(template_name) do
      nil ->
        {:error, :template_not_found}

      template ->
        # Ensure template is active
        if template.status == "active" do
          # Render template with variables in the requested locale
          locale = Keyword.get(opts, :locale, "en")
          rendered = Provider.current().render_template(template, variables, locale)

          # Build email
          email =
            new()
            |> to(recipient)
            |> from(Keyword.get(opts, :from, {get_from_name(), get_from_email()}))
            |> subject(rendered.subject)
            |> html_body(rendered.html_body)
            |> text_body(rendered.text_body)

          # Add reply-to if provided
          email =
            if reply_to = Keyword.get(opts, :reply_to) do
              reply_to(email, reply_to)
            else
              email
            end

          # Track template usage
          Provider.current().track_usage(template)

          # Extract source_module from template metadata
          source_module = Provider.current().get_source_module(template)

          # Prepare delivery options with category and source_module from template
          delivery_opts =
            opts
            |> Keyword.put(:template_name, template_name)
            |> Keyword.put(:template_uuid, template.uuid)
            |> Keyword.put_new(:campaign_id, template.category)
            |> Keyword.put(:category, template.category)
            |> Keyword.put_new(:source_module, source_module)
            |> Keyword.put(:provider, detect_provider())

          # Send email with tracking
          deliver_email(email, delivery_opts)
        else
          {:error, :template_inactive}
        end
    end
  end

  @doc """
  Delivers an email using the appropriate mailer.

  If a parent application mailer is configured, delegates to it.
  Otherwise uses the built-in PhoenixKit mailer.

  This function also integrates with the email tracking system to log
  outgoing emails when tracking is enabled. Recipients blocklisted (or over
  the send-rate limits) by the emails module are rejected before any
  tracking or delivery is attempted — see `check_recipient_allowed/1`.
  """
  def deliver_email(email, opts \\ []) do
    with :ok <- check_recipient_allowed(email) do
      # Intercept email for tracking before sending
      tracked_email = Provider.current().intercept_before_send(email, opts)

      mailer = get_mailer()

      result =
        if mailer == __MODULE__ do
          # Use built-in mailer with runtime config for AWS
          deliver_with_runtime_config(tracked_email, mailer)
        else
          # Check if parent mailer also uses AWS SES
          app = PhoenixKit.Config.get_parent_app()
          config = Application.get_env(app, mailer, [])

          if config[:adapter] == Swoosh.Adapters.AmazonSES do
            # Parent mailer uses AWS SES, provide runtime config
            deliver_with_runtime_config(tracked_email, mailer, app)
          else
            # Non-AWS mailer, use standard delivery
            mailer.deliver(tracked_email)
          end
        end

      # Handle post-send tracking updates
      Provider.current().handle_after_send(tracked_email, result)

      result
    end
  end

  # Deliver email with runtime configuration for AWS SES
  defp deliver_with_runtime_config(email, mailer, app \\ :phoenix_kit) do
    config =
      if app == :phoenix_kit do
        # Use PhoenixKit config for built-in mailer
        PhoenixKit.Config.get(mailer, [])
      else
        # Use parent app config for parent mailer
        PhoenixKit.Config.get_parent_app_config(mailer, [])
      end

    # If using AWS SES, override with runtime settings from DB
    runtime_config =
      if config[:adapter] == Swoosh.Adapters.AmazonSES do
        if Provider.current().aws_configured?() do
          config
          |> Keyword.put(:region, Provider.current().get_aws_region())
          |> Keyword.put(:access_key, Provider.current().get_aws_access_key())
          |> Keyword.put(:secret, Provider.current().get_aws_secret_key())
        else
          config
        end
      else
        config
      end

    # Use Swoosh.Mailer.deliver with runtime config
    Swoosh.Mailer.deliver(email, runtime_config)
  end

  @doc """
  Delivers an email via a specific Integrations connection (AWS SES,
  universal SMTP, or Brevo API), selected by the connection's `uuid`.

  Unlike `deliver_email/2`, this does **not** go through
  `deliver_with_runtime_config/2` — that path is hardcoded to AWS SES
  (`config[:adapter] == Swoosh.Adapters.AmazonSES`, credentials only from
  `Provider.current().get_aws_*`), so a Brevo or SMTP send routed through
  it would be misrouted or ignored. This function resolves the Swoosh
  adapter and config directly from the chosen integration's stored
  credentials instead, while preserving the same interception seam
  `deliver_email/2` uses so tracking keeps working.

  ## Returns

  - `{:ok, term()}` — delivered
  - `{:error, {:blocked, atom()}}` — recipient is blocklisted or over the
    emails module's send-rate limits (checked before the integration is
    even resolved)
  - `{:error, :not_configured | :deleted}` — the integration uuid didn't resolve
  - `{:error, {:unsupported_provider, String.t()}}` — the integration's
    provider has no known Swoosh adapter mapping
  """
  @spec deliver_via_integration(Swoosh.Email.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def deliver_via_integration(email, integration_uuid, opts \\ [])
      when is_binary(integration_uuid) do
    with :ok <- check_recipient_allowed(email),
         {:ok, creds} <- Integrations.get_credentials(integration_uuid),
         {:ok, {adapter, config}} <- swoosh_config_for(creds) do
      # Tell the tracking interceptor which provider actually sent this. Without
      # it, `detect_provider/2` falls back to the host app's static mailer
      # adapter (e.g. SES) and mis-attributes SMTP/Brevo integration sends
      # (plus a "no provider data" warning per send). `put_new` lets an explicit
      # caller override win.
      tracked_opts = Keyword.put_new(opts, :provider, creds["provider"])
      tracked_email = Provider.current().intercept_before_send(email, tracked_opts)
      result = Swoosh.Mailer.deliver(tracked_email, [adapter: adapter] ++ config)
      Provider.current().handle_after_send(tracked_email, result)
      result
    end
  end

  @doc false
  # Maps an Integrations connection's decrypted credentials to a Swoosh
  # `{adapter, config}` pair. Not `defp` so `deliver_via_integration/3`'s
  # provider selection can be unit-tested without triggering real
  # delivery — `@doc false` because it's an internal seam, not part of
  # the public API. The returned config carries DECRYPTED secrets — callers
  # must never log or `inspect` it.
  @spec swoosh_config_for(map()) :: {:ok, {module(), keyword()}} | {:error, term()}
  def swoosh_config_for(%{"provider" => "aws_ses"} = creds) do
    {:ok,
     {Swoosh.Adapters.AmazonSES,
      [
        region: creds["aws_region"],
        access_key: creds["access_key"],
        secret: creds["secret_key"]
      ]}}
  end

  def swoosh_config_for(%{"provider" => "smtp"} = creds) do
    case parse_smtp_port(creds["port"]) do
      nil ->
        # A non-integer port silently becomes gen_smtp's default (25), which
        # would relay plaintext to an unintended server — surface it instead.
        {:error, {:invalid_smtp_port, creds["port"]}}

      port ->
        base = [
          relay: creds["host"],
          port: port,
          username: creds["username"],
          password: creds["password"]
        ]

        # Port 465 = implicit TLS (SMTPS): gen_smtp decides the protocol
        # solely from the `ssl` option (gen_smtp_client.erl:854 — `ssl:true`
        # → ssl socket, else plaintext tcp). The `tls` option only controls a
        # STARTTLS *upgrade after* a plaintext connect, so `tls: :always` on
        # 465 would open plaintext to an SMTPS port and hang. Everything else
        # (587 submission, etc.) uses mandatory STARTTLS — `:always` fails
        # closed rather than downgrade to plaintext while sending relay creds.
        transport = if port == 465, do: [ssl: true], else: [tls: :always]
        {:ok, {Swoosh.Adapters.SMTP, base ++ transport}}
    end
  end

  def swoosh_config_for(%{"provider" => "brevo_api"} = creds) do
    {:ok, {Swoosh.Adapters.Brevo, [api_key: creds["api_key"]]}}
  end

  def swoosh_config_for(%{"provider" => provider}),
    do: {:error, {:unsupported_provider, provider}}

  def swoosh_config_for(_creds), do: {:error, :unsupported_provider}

  # Setup fields are typed `:number` but travel through LiveView form
  # params and JSONB storage as strings — normalize either shape.
  defp parse_smtp_port(port) when is_integer(port), do: port

  defp parse_smtp_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_smtp_port(_), do: nil

  # Checks every `to` recipient against the emails module's blocklist/rate
  # limiter before a message reaches a Swoosh adapter. Must run before
  # `intercept_before_send/2` — that callback returns a `Swoosh.Email.t()`
  # with no abort channel, so it has no way to refuse a blocked send. This
  # is the one chokepoint `deliver_email/2` and `deliver_via_integration/3`
  # both pass through, so enforcement lives here rather than in the
  # interceptor.
  @spec check_recipient_allowed(Swoosh.Email.t()) :: :ok | {:error, {:blocked, atom()}}
  defp check_recipient_allowed(%Swoosh.Email{to: recipients}) do
    Enum.reduce_while(recipients, :ok, fn {_name, address}, :ok ->
      case check_blocklisted(address) do
        :ok -> {:cont, :ok}
        {:blocked, reason} -> {:halt, {:error, {:blocked, reason}}}
      end
    end)
  end

  defp check_blocklisted(address) do
    if Code.ensure_loaded?(@emails_rate_limiter) and
         function_exported?(@emails_rate_limiter, :check_blocklist, 1) do
      # apply/3 intentionally, to avoid compile-time module resolution --
      # a direct `@emails_rate_limiter.check_blocklist/1` call would fail
      # `--warnings-as-errors` when the optional emails package isn't a
      # dependency (the compiler can prove the module is undefined).
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(@emails_rate_limiter, :check_blocklist, [address])
    else
      :ok
    end
  rescue
    error ->
      # Fail open: this gate sits in front of ALL outbound mail (auth
      # included), so a transient DB hiccup must not take delivery down.
      Logger.error("Recipient blocklist check failed, allowing send: #{inspect(error)}")
      :ok
  end

  @doc """
  Sends a magic link email to the user.

  Uses the 'magic_link' template from the database if available,
  falls back to hardcoded template if not found.

  ## Examples

      iex> PhoenixKit.Mailer.send_magic_link_email(user, "https://app.com/magic/token123")
      {:ok, %Swoosh.Email{}}
  """
  def send_magic_link_email(%User{} = user, magic_link_url) when is_binary(magic_link_url) do
    # Variables for template substitution
    template_variables = %{
      "user_email" => user.email,
      "magic_link_url" => magic_link_url
    }

    # Try to get template from database, fallback to text-only
    {subject, html_body, text_body, db_template} =
      case Provider.current().get_active_template_by_name("magic_link") do
        nil ->
          {
            "Your secure login link",
            nil,
            magic_link_text_body(user, magic_link_url),
            nil
          }

        template ->
          rendered = Provider.current().render_template(template, template_variables)
          {rendered.subject, rendered.html_body, rendered.text_body, template}
      end

    email =
      new()
      |> to({user.email, user.email})
      |> from({get_from_name(), get_from_email()})
      |> subject(subject)
      |> html_body(html_body)
      |> text_body(text_body)

    # Track template usage if using database template
    if db_template, do: Provider.current().track_usage(db_template)

    deliver_email(email,
      user_uuid: user.uuid,
      template_name: "magic_link",
      campaign_id: "authentication",
      category: "system",
      source_module: "users",
      provider: detect_provider()
    )
  end

  # Text version of the magic link email
  defp magic_link_text_body(_user, magic_link_url) do
    """
    Your login link: #{magic_link_url}
    This link expires in 15 minutes.
    """
  end

  # Detect current email provider from configuration
  defp detect_provider do
    mailer = get_mailer()

    if mailer == __MODULE__ do
      detect_builtin_provider()
    else
      detect_parent_app_provider(mailer)
    end
  end

  # Detect provider for built-in PhoenixKit mailer
  defp detect_builtin_provider do
    config = PhoenixKit.Config.get(PhoenixKit.Mailer, [])
    adapter = Keyword.get(config, :adapter)
    Provider.current().adapter_to_provider_name(adapter, "phoenix_kit_builtin")
  end

  # Detect provider for parent application mailer
  defp detect_parent_app_provider(mailer) when is_atom(mailer) do
    config = PhoenixKit.Config.get_parent_app_config(mailer, [])
    adapter = Keyword.get(config, :adapter)
    Provider.current().adapter_to_provider_name(adapter, "parent_app_mailer")
  end

  defp detect_parent_app_provider(_mailer), do: "unknown"

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
end
