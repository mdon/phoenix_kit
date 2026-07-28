defmodule PhoenixKit.Mailer.SmtpTransportTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Mailer.SmtpTransport

  defp creds(overrides \\ %{}) do
    Map.merge(
      %{
        "host" => "smtp-relay.brevo.com",
        "port" => "587",
        "username" => "sub1@smtp-brevo.com",
        "password" => "not-a-real-smtp-secret"
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

  describe "security setting (operator override of the port-based guess)" do
    test "blank or \"auto\" keeps the historical port-based behavior" do
      for value <- [nil, "", "auto"] do
        assert {:ok, options} = SmtpTransport.config(creds(%{"security" => value}), [<<1>>])
        assert options[:tls] == :always
        refute Keyword.has_key?(options, :ssl)
      end
    end

    test "\"ssl\" forces implicit TLS on a non-465 port" do
      assert {:ok, options} =
               SmtpTransport.config(creds(%{"security" => "ssl", "port" => "2465"}), [<<1>>])

      assert options[:ssl] == true
      assert options[:sockopts][:verify] == :verify_peer
      refute Keyword.has_key?(options, :tls)
    end

    test "\"starttls\" forces the upgrade path even on 465" do
      assert {:ok, options} =
               SmtpTransport.config(creds(%{"security" => "starttls", "port" => 465}), [<<1>>])

      assert options[:tls] == :always
      refute Keyword.has_key?(options, :ssl)
    end

    test "\"starttls_optional\" downgrades the fail-closed rule a credentialed relay would get" do
      assert {:ok, options} =
               SmtpTransport.config(creds(%{"security" => "starttls_optional"}), [<<1>>])

      assert options[:tls] == :if_available
    end

    test "\"none\" says :never — gen_smtp's default would still upgrade opportunistically" do
      assert {:ok, options} = SmtpTransport.config(creds(%{"security" => "none"}), [])

      assert options[:tls] == :never
      refute Keyword.has_key?(options, :ssl)
      refute Keyword.has_key?(options, :tls_options)
    end

    test "an unknown value is rejected rather than silently treated as auto" do
      assert {:error, {:invalid_security, "tls1.3-please"}} =
               SmtpTransport.config(creds(%{"security" => "tls1.3-please"}))
    end
  end

  describe "certificate verification setting" do
    test "verify_none is honored, and no longer needs a CA store to build a config" do
      # The fail-closed :no_ca_store branch exists for operators who did NOT
      # choose this; choosing it is the documented escape hatch for an internal
      # relay with a self-signed certificate.
      assert {:ok, options} = SmtpTransport.config(creds(%{"verify_cert" => "verify_none"}), [])

      assert options[:tls_options] == [verify: :verify_none]
    end

    test "an unknown value is rejected" do
      assert {:error, {:invalid_verify_cert, "sometimes"}} =
               SmtpTransport.config(creds(%{"verify_cert" => "sometimes"}))
    end
  end

  describe "custom CA bundle" do
    test "a PEM bundle replaces the system store for this connection" do
      pem = :public_key.pem_encode([{:Certificate, <<9, 9, 9>>, :not_encrypted}])

      assert {:ok, options} = SmtpTransport.config(creds(%{"ca_cert" => pem}), [<<1, 2, 3>>])

      assert options[:tls_options][:cacerts] == [<<9, 9, 9>>]
    end

    test "a PEM bundle is enough on a host with no system store at all" do
      pem = :public_key.pem_encode([{:Certificate, <<9, 9, 9>>, :not_encrypted}])

      assert {:ok, options} = SmtpTransport.config(creds(%{"ca_cert" => pem}), [])
      assert options[:tls_options][:verify] == :verify_peer
    end

    test "garbage is rejected instead of silently falling back to the system store" do
      # Falling back would leave the operator staring at a handshake failure
      # against a CA they believe they installed.
      assert {:error, :invalid_ca_cert} =
               SmtpTransport.config(creds(%{"ca_cert" => "not a certificate"}))
    end
  end

  describe "auth setting" do
    test "defaults to gen_smtp's :if_available, so existing connections send unchanged" do
      assert {:ok, options} = SmtpTransport.config(creds(), [<<1>>])
      assert options[:auth] == :if_available
    end

    test "always and never are passed through" do
      assert {:ok, always} = SmtpTransport.config(creds(%{"auth" => "always"}), [<<1>>])
      assert {:ok, never} = SmtpTransport.config(creds(%{"auth" => "never"}), [<<1>>])

      assert always[:auth] == :always
      assert never[:auth] == :never
    end

    test "an unknown value is rejected" do
      assert {:error, {:invalid_auth, "maybe"}} =
               SmtpTransport.config(creds(%{"auth" => "maybe"}))
    end
  end

  describe "timeout setting" do
    test "is absent unless configured, leaving gen_smtp's own default alone" do
      assert {:ok, options} = SmtpTransport.config(creds(), [<<1>>])
      refute Keyword.has_key?(options, :timeout)
    end

    test "is given to gen_smtp in milliseconds" do
      assert {:ok, from_string} = SmtpTransport.config(creds(%{"timeout" => "30"}), [<<1>>])
      assert {:ok, from_int} = SmtpTransport.config(creds(%{"timeout" => 30}), [<<1>>])

      assert from_string[:timeout] == 30_000
      assert from_int[:timeout] == 30_000
    end

    test "rejects values that would mean 'no timeout' by accident" do
      assert {:error, {:invalid_timeout, "0"}} = SmtpTransport.config(creds(%{"timeout" => "0"}))

      assert {:error, {:invalid_timeout, "soon"}} =
               SmtpTransport.config(creds(%{"timeout" => "soon"}))
    end
  end
end
