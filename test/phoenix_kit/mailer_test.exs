defmodule PhoenixKit.MailerTest.FakeBrevoApiClient do
  @moduledoc false
  # Stands in for `Swoosh.ApiClient` (`config :swoosh, :api_client, ...`)
  # so the real `Swoosh.Adapters.Brevo` code path can be exercised without
  # any real HTTP call — `post/4` runs synchronously in the calling
  # (test) process, so messaging `self()` is safe.
  @behaviour Swoosh.ApiClient

  @impl true
  def post(url, headers, body, _email) do
    send(self(), {:fake_brevo_post, url, headers, body})
    {:ok, 201, [], Jason.encode!(%{"messageId" => "test-message-id"})}
  end
end

defmodule PhoenixKit.Modules.Emails.RateLimiter do
  @moduledoc false
  # Stands in for the optional `emails` package's real RateLimiter (core has
  # no dependency on `phoenix_kit_emails` — confirmed absent from
  # `mix.exs`), so `Mailer.check_recipient_allowed/1`'s soft-call
  # (`Code.ensure_loaded?/1` + `function_exported?/3` + `apply/3`) can be
  # exercised for real instead of only the "module absent" branch — the
  # same reason `FakeBrevoApiClient`/`TrackingProvider` below stand in for
  # other optional/external behaviour. Mirrors the real
  # `check_blocklist/1` contract: `:ok | {:blocked, reason}`, deterministic on
  # the recipient address so no shared mutable state is needed.
  #
  # The Mailer deliberately calls `check_blocklist/1`, NOT `check_limits/1` —
  # the latter also enforces per-recipient/global send caps, which must not
  # gate app-wide mail or cap bulk broadcasts (see the Mailer's note).
  def check_blocklist("blocked@example.com"), do: {:blocked, :blocklist}
  def check_blocklist(_address), do: :ok
end

defmodule PhoenixKit.MailerTest.TrackingProvider do
  @moduledoc false
  # A `PhoenixKit.Email.Provider` implementation that notifies the test
  # process on intercept/after-send, to prove `deliver_via_integration/3`
  # preserves the same tracking seam `deliver_email/2` uses. All other
  # callbacks mirror `PhoenixKit.Email.DefaultProvider`'s no-ops.
  @behaviour PhoenixKit.Email.Provider

  @impl true
  def intercept_before_send(email, opts) do
    send(self(), {:intercept_before_send_called, opts})
    email
  end

  @impl true
  def handle_after_send(_email, result) do
    send(self(), {:handle_after_send_called, result})
    :ok
  end

  @impl true
  def get_active_template_by_name(_name), do: nil
  @impl true
  def render_template(_t, _v), do: %{subject: "", html_body: "", text_body: ""}
  @impl true
  def render_template(_t, _v, _l), do: %{subject: "", html_body: "", text_body: ""}
  @impl true
  def track_usage(_template), do: :ok
  @impl true
  def get_source_module(_template), do: nil
  @impl true
  def get_aws_region, do: ""
  @impl true
  def get_aws_access_key, do: ""
  @impl true
  def get_aws_secret_key, do: ""
  @impl true
  def aws_configured?, do: false
  @impl true
  def send_test_tracking_email(_recipient_email, _user_uuid), do: {:error, :not_supported}
  @impl true
  def adapter_to_provider_name(_adapter, default), do: default
end

defmodule PhoenixKit.MailerTest do
  # async: false — one test swaps the global `:swoosh, :api_client` and
  # `:phoenix_kit, :email_provider` app env, which `Mailer.deliver_email/2`
  # and other adapters read too; keep it from racing concurrently-running
  # async test files.
  use PhoenixKit.DataCase, async: false

  import Swoosh.Email

  alias PhoenixKit.Integrations
  alias PhoenixKit.Mailer
  alias PhoenixKit.MailerTest.FakeBrevoApiClient
  alias PhoenixKit.MailerTest.TrackingProvider

  describe "swoosh_config_for/1" do
    test "aws_ses credentials build an AmazonSES adapter config" do
      creds = %{
        "provider" => "aws_ses",
        "access_key" => "AKIA_T",
        "secret_key" => "S",
        "aws_region" => "eu-central-1"
      }

      assert {:ok, {Swoosh.Adapters.AmazonSES, config}} = Mailer.swoosh_config_for(creds)
      assert config[:region] == "eu-central-1"
      assert config[:access_key] == "AKIA_T"
      assert config[:secret] == "S"
    end

    test "smtp credentials build an SMTP adapter config, port as string" do
      creds = %{
        "provider" => "smtp",
        "host" => "smtp-relay.brevo.com",
        "port" => "587",
        "username" => "sub1@smtp-brevo.com",
        "password" => "xsmtpsib-1"
      }

      assert {:ok, {Swoosh.Adapters.SMTP, config}} = Mailer.swoosh_config_for(creds)
      assert config[:relay] == "smtp-relay.brevo.com"
      assert config[:port] == 587
      assert config[:username] == "sub1@smtp-brevo.com"
      assert config[:password] == "xsmtpsib-1"
      # 587 = mandatory STARTTLS, fail-closed (no plaintext downgrade)
      assert config[:tls] == :always
      refute Keyword.has_key?(config, :ssl)
    end

    test "smtp credentials on port 465 use implicit TLS (ssl: true), not STARTTLS" do
      creds = %{
        "provider" => "smtp",
        "host" => "smtp.example.com",
        "port" => 465,
        "username" => "user",
        "password" => "pw"
      }

      assert {:ok, {Swoosh.Adapters.SMTP, config}} = Mailer.swoosh_config_for(creds)
      assert config[:port] == 465
      # gen_smtp opens an SSL socket only when `ssl: true`; `tls:` is STARTTLS-only
      assert config[:ssl] == true
      refute Keyword.has_key?(config, :tls)
    end

    test "an smtp relay with no credentials allows opportunistic STARTTLS" do
      # e.g. a local dev relay (MailHog:1025) or an internal plaintext
      # smarthost — nothing on the wire to protect, so mandatory STARTTLS
      # would only break it.
      creds = %{"provider" => "smtp", "host" => "localhost", "port" => 1025}

      assert {:ok, {Swoosh.Adapters.SMTP, config}} = Mailer.swoosh_config_for(creds)
      assert config[:port] == 1025
      assert config[:tls] == :if_available
    end

    test "smtp credentials with an unparseable port are rejected" do
      creds = %{
        "provider" => "smtp",
        "host" => "smtp.example.com",
        "port" => "not-a-port",
        "username" => "user",
        "password" => "pw"
      }

      assert {:error, {:invalid_smtp_port, "not-a-port"}} = Mailer.swoosh_config_for(creds)
    end

    test "brevo_api credentials build a Brevo adapter config" do
      creds = %{"provider" => "brevo_api", "api_key" => "xkeysib-test"}

      assert {:ok, {Swoosh.Adapters.Brevo, config}} = Mailer.swoosh_config_for(creds)
      assert config[:api_key] == "xkeysib-test"
    end

    test "unknown provider is rejected" do
      assert {:error, {:unsupported_provider, "openrouter"}} =
               Mailer.swoosh_config_for(%{"provider" => "openrouter"})
    end

    test "missing provider key is rejected" do
      assert {:error, :unsupported_provider} = Mailer.swoosh_config_for(%{})
    end
  end

  describe "deliver_email/2 — recipient blocklist enforcement (E2)" do
    test "a blocklisted recipient is rejected without attempting delivery" do
      email =
        new()
        |> to("blocked@example.com")
        |> Swoosh.Email.from("from@example.com")
        |> subject("Hi")

      assert {:error, {:blocked, :blocklist}} = Mailer.deliver_email(email)
      refute_received {:email, _}
    end

    test "a normal recipient still delivers" do
      email =
        new() |> to("ok@example.com") |> Swoosh.Email.from("from@example.com") |> subject("Hi")

      assert {:ok, _} = Mailer.deliver_email(email)
      assert_received {:email, _}
    end

    test "a blocklisted address in cc is rejected (suppression cannot be bypassed)" do
      email =
        new()
        |> to("ok@example.com")
        |> Swoosh.Email.cc("blocked@example.com")
        |> Swoosh.Email.from("from@example.com")
        |> subject("Hi")

      assert {:error, {:blocked, :blocklist}} = Mailer.deliver_email(email)
      refute_received {:email, _}
    end

    test "a blocklisted address in bcc is rejected (suppression cannot be bypassed)" do
      email =
        new()
        |> to("ok@example.com")
        |> Swoosh.Email.bcc("blocked@example.com")
        |> Swoosh.Email.from("from@example.com")
        |> subject("Hi")

      assert {:error, {:blocked, :blocklist}} = Mailer.deliver_email(email)
      refute_received {:email, _}
    end
  end

  describe "deliver_via_integration/3" do
    test "returns an error when the integration uuid doesn't resolve" do
      email =
        new() |> to("to@example.com") |> Swoosh.Email.from("from@example.com") |> subject("Hi")

      assert {:error, :deleted} =
               Mailer.deliver_via_integration(email, Ecto.UUID.generate())
    end

    test "a blocklisted recipient is rejected before the integration is even resolved (E2)" do
      email =
        new()
        |> to("blocked@example.com")
        |> Swoosh.Email.from("from@example.com")
        |> subject("Hi")

      # A bogus uuid would normally surface as {:error, :deleted} (see test
      # above) -- getting {:blocked, ...} instead proves the recipient check
      # runs first, ahead of Integrations.get_credentials/1.
      assert {:error, {:blocked, :blocklist}} =
               Mailer.deliver_via_integration(email, Ecto.UUID.generate())
    end

    test "returns an unsupported-provider error without attempting delivery" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("openrouter", "test")
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "sk-test"})

      email =
        new() |> to("to@example.com") |> Swoosh.Email.from("from@example.com") |> subject("Hi")

      assert {:error, {:unsupported_provider, "openrouter"}} =
               Mailer.deliver_via_integration(email, uuid)
    end

    test "delivers via brevo_api, capturing the request and firing tracking hooks" do
      original_api_client = Application.get_env(:swoosh, :api_client)
      original_provider = Application.get_env(:phoenix_kit, :email_provider)

      Application.put_env(:swoosh, :api_client, FakeBrevoApiClient)
      Application.put_env(:phoenix_kit, :email_provider, TrackingProvider)

      on_exit(fn ->
        if original_api_client,
          do: Application.put_env(:swoosh, :api_client, original_api_client),
          else: Application.delete_env(:swoosh, :api_client)

        if original_provider,
          do: Application.put_env(:phoenix_kit, :email_provider, original_provider),
          else: Application.delete_env(:phoenix_kit, :email_provider)
      end)

      {:ok, %{uuid: uuid}} = Integrations.add_connection("brevo_api", "test")
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "xkeysib-test"})

      email =
        new()
        |> to("to@example.com")
        |> Swoosh.Email.from("from@example.com")
        |> subject("Hello via Brevo")
        |> text_body("Hi there")

      assert {:ok, %{id: "test-message-id"}} = Mailer.deliver_via_integration(email, uuid)

      assert_received {:fake_brevo_post, url, headers, _body}
      assert IO.iodata_to_binary(url) == "https://api.brevo.com/v3/smtp/email"
      assert Enum.any?(headers, fn {k, v} -> k == "Api-Key" and v == "xkeysib-test" end)

      assert_received {:intercept_before_send_called, intercept_opts}
      # provider is injected so the tracking interceptor attributes the send to
      # the integration's provider, not the host app's static mailer adapter.
      assert intercept_opts[:provider] == "brevo_api"
      assert_received {:handle_after_send_called, {:ok, %{id: "test-message-id"}}}
    end
  end
end
