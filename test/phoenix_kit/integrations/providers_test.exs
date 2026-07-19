defmodule PhoenixKit.Integrations.ProvidersTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Integrations.Providers

  describe "all/0" do
    test "returns a list of provider maps" do
      providers = Providers.all()
      assert is_list(providers)
      assert length(providers) >= 2
    end

    test "includes google provider" do
      providers = Providers.all()
      google = Enum.find(providers, &(&1.key == "google"))
      assert google != nil
      assert google.name == "Google"
      assert google.auth_type == :oauth2
      assert google.oauth_config != nil
      assert google.oauth_config[:auth_url] =~ "accounts.google.com"
      assert google.oauth_config[:token_url] =~ "oauth2.googleapis.com"
      assert google.oauth_config[:userinfo_url] =~ "googleapis.com/oauth2"
    end

    test "includes openrouter provider" do
      providers = Providers.all()
      openrouter = Enum.find(providers, &(&1.key == "openrouter"))
      assert openrouter != nil
      assert openrouter.name == "OpenRouter"
      assert openrouter.auth_type == :api_key
      assert openrouter.oauth_config == nil
    end

    test "google has required setup fields" do
      google = Providers.get("google")
      field_keys = Enum.map(google.setup_fields, & &1.key)
      assert "client_id" in field_keys
      assert "client_secret" in field_keys
    end

    test "openrouter has required setup fields" do
      openrouter = Providers.get("openrouter")
      field_keys = Enum.map(openrouter.setup_fields, & &1.key)
      assert "api_key" in field_keys
    end

    test "all providers have required keys" do
      for provider <- Providers.all() do
        assert is_binary(provider.key), "provider missing key"
        assert is_binary(provider.name), "#{provider.key} missing name"
        assert is_binary(provider.description), "#{provider.key} missing description"
        assert is_binary(provider.icon), "#{provider.key} missing icon"
        assert provider.auth_type in [:oauth2, :api_key, :key_secret, :bot_token, :credentials]
        assert is_list(provider.setup_fields), "#{provider.key} missing setup_fields"
        assert is_list(provider.capabilities), "#{provider.key} missing capabilities"
      end
    end
  end

  describe "aws_ses provider" do
    test "is registered and produces usable credentials" do
      p = Providers.get("aws_ses")
      assert p.auth_type == :key_secret
      keys = Enum.map(p.setup_fields, & &1.key)
      assert "access_key" in keys and "secret_key" in keys and "aws_region" in keys
      assert "secret_key" in Encryption.sensitive_fields()
      assert :email_send in p.capabilities

      # end-to-end: headless save must yield retrievable credentials
      {:ok, %{uuid: uuid}} = Integrations.add_connection("aws_ses", "test")

      {:ok, _} =
        Integrations.save_setup(uuid, %{
          "access_key" => "AKIA_T",
          "secret_key" => "S",
          "aws_region" => "eu-central-1"
        })

      assert {:ok, %{"access_key" => "AKIA_T"}} = Integrations.get_credentials(uuid)
    end
  end

  describe "smtp provider (universal)" do
    test "is registered and produces usable credentials, with multiple named connections" do
      p = Providers.get("smtp")
      assert p.auth_type == :credentials
      assert p.oauth_config == nil
      keys = Enum.map(p.setup_fields, & &1.key)
      assert "host" in keys and "port" in keys and "username" in keys and "password" in keys
      assert "password" in Encryption.sensitive_fields()
      assert :email_send in p.capabilities

      # end-to-end: headless save + validate must yield retrievable credentials
      {:ok, %{uuid: uuid1}} = Integrations.add_connection("smtp", "SMTP 1")

      {:ok, _} =
        Integrations.save_setup(uuid1, %{
          "host" => "smtp-relay.brevo.com",
          "port" => "587",
          "username" => "sub1@smtp-brevo.com",
          "password" => "not-a-real-smtp-secret"
        })

      # No validate_connection here on purpose: SMTP is now validated for real
      # (a live session + AUTH), so fabricated credentials are rejected -- which
      # is the point. Retrievability comes from save_setup stamping "configured"
      # once every required flat field is present.
      assert {:ok, %{"host" => "smtp-relay.brevo.com", "password" => "not-a-real-smtp-secret"}} =
               Integrations.get_credentials(uuid1)

      # a second named connection of the same provider coexists independently
      {:ok, %{uuid: uuid2}} = Integrations.add_connection("smtp", "SMTP 2")

      {:ok, _} =
        Integrations.save_setup(uuid2, %{
          "host" => "smtp.example.com",
          "port" => "2525",
          "username" => "user2",
          "password" => "pw2"
        })

      assert {:ok, %{"host" => "smtp.example.com"}} = Integrations.get_credentials(uuid2)

      connections = Integrations.list_connections("smtp")
      uuids = Enum.map(connections, & &1.uuid)
      assert uuid1 in uuids and uuid2 in uuids
    end

    test "Test Connection really connects: an unreachable relay is rejected" do
      # Before the validators existed this returned :ok and the connection was
      # stamped "connected" -- a green check on a relay that does not exist.
      {:ok, %{uuid: uuid}} = Integrations.add_connection("smtp", "dead relay")

      {:ok, _} =
        Integrations.save_setup(uuid, %{
          "host" => "127.0.0.1",
          "port" => "1",
          "username" => "u",
          "password" => "p"
        })

      assert {:error, _reason} = Integrations.validate_connection(uuid)
    end
  end

  describe "brevo_api provider" do
    test "is registered and produces usable credentials" do
      p = Providers.get("brevo_api")
      assert p.auth_type == :api_key
      assert p.oauth_config == nil
      assert p.base_url == "https://api.brevo.com/v3"
      keys = Enum.map(p.setup_fields, & &1.key)
      assert "api_key" in keys
      assert "api_key" in Encryption.sensitive_fields()
      assert :email_send in p.capabilities

      {:ok, %{uuid: uuid}} = Integrations.add_connection("brevo_api", "test")
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "xkeysib-test"})

      assert {:ok, %{"api_key" => "xkeysib-test"}} = Integrations.get_credentials(uuid)
    end
  end

  describe "get/1" do
    test "returns provider for known key" do
      assert %{key: "google"} = Providers.get("google")
      assert %{key: "openrouter"} = Providers.get("openrouter")
    end

    test "returns nil for unknown key" do
      assert Providers.get("nonexistent") == nil
      assert Providers.get("") == nil
    end
  end

  describe "used_by_modules/0" do
    test "returns a map" do
      result = Providers.used_by_modules()
      assert is_map(result)
    end
  end

  describe "clear_cache/0" do
    test "clears and repopulates on next call" do
      # Populate cache
      providers1 = Providers.all()
      assert is_list(providers1)

      # Clear
      :ok = Providers.clear_cache()

      # Should repopulate
      providers2 = Providers.all()
      assert providers1 == providers2
    end

    test "safe to call when cache is empty" do
      Providers.clear_cache()
      assert :ok = Providers.clear_cache()
    end
  end
end
