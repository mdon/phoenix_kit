defmodule PhoenixKit.Mailer.SmtpTransportTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Mailer.SmtpTransport

  defp creds(overrides \\ %{}) do
    Map.merge(
      %{
        "host" => "smtp-relay.brevo.com",
        "port" => "587",
        "username" => "sub1@smtp-brevo.com",
        "password" => "xsmtpsib-1"
      },
      overrides
    )
  end

  describe "TLS (the options gen_smtp does not supply and OTP now demands)" do
    test "STARTTLS carries verified TLS options" do
      assert {:ok, options} = SmtpTransport.config(creds())

      assert options[:tls] == :always
      refute Keyword.has_key?(options, :ssl)

      tls = options[:tls_options]
      assert tls[:verify] == :verify_peer
      assert tls[:cacerts] != nil
      assert tls[:server_name_indication] == ~c"smtp-relay.brevo.com"
      assert tls[:customize_hostname_check] != nil
    end

    test "implicit TLS (465) puts the same options on sockopts, where :ssl.connect reads them" do
      assert {:ok, options} = SmtpTransport.config(creds(%{"port" => 465}))

      assert options[:ssl] == true
      refute Keyword.has_key?(options, :tls)

      # Without these, the connect dies outright:
      # {:options, :incompatible, [verify: :verify_peer, cacerts: :undefined]}
      assert options[:sockopts][:verify] == :verify_peer
      assert options[:sockopts][:cacerts] != nil
    end

    test "depth is set explicitly — gen_smtp's own default of 0 rejects every real chain" do
      # smtp_socket.erl ships {depth, 0} and merges it into whatever we pass.
      # Depth 0 means "no intermediate CAs", so a normal leaf+intermediate chain
      # fails verification and the handshake dies with :tls_failed. Verified
      # against a live relay: omit this and the connection fails every time.
      # If you are tempted to delete this as a redundant default — don't.
      assert {:ok, options} = SmtpTransport.config(creds())
      assert options[:tls_options][:depth] >= 1

      assert {:ok, implicit} = SmtpTransport.config(creds(%{"port" => 465}))
      assert implicit[:sockopts][:depth] >= 1
    end

    test "a credential-less relay may use opportunistic TLS" do
      relay = creds(%{"host" => "localhost", "port" => 1025, "username" => "", "password" => ""})

      assert {:ok, options} = SmtpTransport.config(relay)
      assert options[:tls] == :if_available
      assert options[:tls_options][:verify] == :verify_peer
    end

    test "SNI is disabled rather than sent empty when there is no host" do
      assert {:ok, options} = SmtpTransport.config(creds(%{"host" => nil}))
      assert options[:tls_options][:server_name_indication] == :disable
    end
  end

  describe "MX lookups" do
    test "are disabled: an explicitly configured smarthost is an address, not a domain" do
      # Otherwise gen_smtp connects to whatever the relay's MX records point at
      # while we pin SNI + the hostname check to the configured name — a
      # guaranteed certificate mismatch.
      assert {:ok, options} = SmtpTransport.config(creds())
      assert options[:no_mx_lookups] == true
    end
  end

  describe "port" do
    test "is accepted as an integer or a string (JSONB and form params disagree)" do
      assert {:ok, from_string} = SmtpTransport.config(creds(%{"port" => "2525"}))
      assert {:ok, from_int} = SmtpTransport.config(creds(%{"port" => 2525}))
      assert from_string[:port] == 2525
      assert from_int[:port] == 2525
    end

    test "is rejected when unparseable, instead of silently becoming gen_smtp's default 25" do
      assert {:error, {:invalid_smtp_port, "not-a-port"}} =
               SmtpTransport.config(creds(%{"port" => "not-a-port"}))
    end
  end

  describe "no CA store (a minimal production image)" do
    test "a relay we send a password to fails closed" do
      # Not a theoretical branch: it fires exactly where nobody can watch it. Without
      # a CA store there is nothing to verify the relay against, and the alternative —
      # verify: :verify_none — means the sender trusts any certificate at all while
      # the check still shows green. Refusing is the only honest answer.
      assert {:error, :no_ca_store} = SmtpTransport.config(creds(), [])
    end

    test "a relay with no credentials degrades instead, because it has nothing to leak" do
      creds = creds(%{"username" => "", "password" => ""})

      assert {:ok, options} = SmtpTransport.config(creds, [])
      assert Keyword.fetch!(options, :tls) == :if_available
      assert Keyword.fetch!(options, :tls_options)[:verify] == :verify_none
    end

    test "with a CA store, the same relay verifies the peer" do
      assert {:ok, options} = SmtpTransport.config(creds(), [<<1, 2, 3>>])
      tls = Keyword.fetch!(options, :tls_options)

      assert tls[:verify] == :verify_peer
      assert tls[:cacerts] == [<<1, 2, 3>>]
    end
  end
end
