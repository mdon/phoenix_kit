defmodule PhoenixKit.Mailer.SmtpEndpointPolicyTest do
  # async: false — `enabled?/0` is read from the application environment, and
  # one describe block below sets it.
  use ExUnit.Case, async: false

  alias PhoenixKit.Mailer.SmtpEndpointPolicy

  # What `SmtpTransport.config/2` builds for a STARTTLS relay — the shape the
  # policy receives at both connect sites.
  defp starttls_options(host, port \\ 587) do
    [
      relay: host,
      port: port,
      username: "u",
      password: "p",
      no_mx_lookups: true,
      auth: :if_available,
      tls: :always,
      tls_options: [verify: :verify_peer, server_name_indication: to_charlist(host)]
    ]
  end

  defp ssl_options(host) do
    [
      relay: host,
      port: 465,
      username: "u",
      password: "p",
      no_mx_lookups: true,
      auth: :if_available,
      ssl: true,
      sockopts: [verify: :verify_peer, server_name_indication: to_charlist(host)]
    ]
  end

  # A resolver that must not be reached.
  defp no_dns do
    test = self()

    fn name, family ->
      send(test, {:resolved, name, family})
      {:error, :nxdomain}
    end
  end

  defp resolver(answers) do
    fn _name, family -> Map.get(answers, family, {:error, :nxdomain}) end
  end

  defp enforce(options, policy, opts \\ []) do
    SmtpEndpointPolicy.enforce(options, policy, Keyword.put_new(opts, :enabled, true))
  end

  describe "enforce/3 when the policy is off" do
    test "a personal connection to an internal host:port passes untouched" do
      options = starttls_options("127.0.0.1", 5432)

      assert {:ok, ^options} =
               SmtpEndpointPolicy.enforce(options, :personal, enabled: false, resolver: no_dns())

      refute_received {:resolved, _, _}
    end
  end

  describe "enforce/3 for a system connection" do
    test "passes untouched even with the policy on" do
      options = starttls_options("pgbouncer", 6432)
      assert {:ok, ^options} = enforce(options, :system, resolver: no_dns())
      refute_received {:resolved, _, _}
    end
  end

  describe "enforce/3 for a personal connection: ports" do
    test "only the mail submission ports are allowed" do
      for port <- [25, 465, 587, 2525] do
        assert {:ok, _} = enforce(starttls_options("203.0.113.10", port), :personal)
      end

      for port <- [22, 80, 443, 1025, 5432, 6432, 6379, 11_211] do
        assert {:error, {:smtp_endpoint_refused, :blocked_port}} =
                 enforce(starttls_options("203.0.113.10", port), :personal)
      end
    end

    test "the port is refused before any name is looked up" do
      assert {:error, {:smtp_endpoint_refused, :blocked_port}} =
               enforce(starttls_options("smtp.example.com", 5432), :personal, resolver: no_dns())

      refute_received {:resolved, _, _}
    end
  end

  describe "enforce/3 for a personal connection: literal addresses" do
    test "loopback, private, shared, link-local, unspecified and multicast are refused" do
      for host <- [
            "127.0.0.1",
            "127.1",
            "10.1.2.3",
            "172.16.0.5",
            "192.168.1.1",
            "100.64.0.1",
            "169.254.169.254",
            "0.0.0.0",
            "224.0.0.1",
            "::1",
            "[::1]",
            "fd00::1",
            "fe80::1",
            "::ffff:127.0.0.1",
            "::"
          ] do
        assert {:error, {:smtp_endpoint_refused, :blocked_address}} =
                 enforce(starttls_options(host), :personal, resolver: no_dns()),
               "expected #{host} to be refused"
      end

      refute_received {:resolved, _, _}
    end

    test "a public literal address is allowed and connected to as written" do
      assert {:ok, options} = enforce(starttls_options("203.0.113.10"), :personal)
      assert options[:relay] == "203.0.113.10"
    end

    test "a public IPv6 literal is connected to over IPv6" do
      assert {:ok, options} = enforce(starttls_options("[2001:db8::25]"), :personal)
      assert options[:relay] == "2001:db8::25"
      assert :inet6 in options[:sockopts]
    end
  end

  describe "enforce/3 for a personal connection: internal names" do
    test "bare and internal-only names are refused without a lookup" do
      for host <- [
            "localhost",
            "LOCALHOST",
            "pgbouncer",
            "postgres.",
            "mail.localhost",
            "printer.local",
            "db.internal",
            "metadata.google.internal",
            "nas.home.arpa"
          ] do
        assert {:error, {:smtp_endpoint_refused, :blocked_host}} =
                 enforce(starttls_options(host), :personal, resolver: no_dns()),
               "expected #{host} to be refused"
      end

      refute_received {:resolved, _, _}
    end
  end

  describe "enforce/3 for a personal connection: resolved names" do
    test "a name that resolves only to public addresses is pinned to the checked address" do
      options = starttls_options("smtp.example.com")

      assert {:ok, pinned} =
               enforce(options, :personal,
                 resolver: resolver(%{inet: {:ok, [{203, 0, 113, 25}]}})
               )

      # The socket goes to the address that was checked — gen_smtp gets no name
      # to resolve again — while TLS still verifies the certificate against the
      # name the operator typed.
      assert pinned[:relay] == "203.0.113.25"
      assert pinned[:tls_options][:server_name_indication] == ~c"smtp.example.com"
      assert Keyword.delete(pinned, :relay) == Keyword.delete(options, :relay)
    end

    test "IPv4 is preferred when both families answer" do
      answers = %{
        inet: {:ok, [{203, 0, 113, 25}]},
        inet6: {:ok, [{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x25}]}
      }

      assert {:ok, pinned} =
               enforce(starttls_options("smtp.example.com"), :personal,
                 resolver: resolver(answers)
               )

      assert pinned[:relay] == "203.0.113.25"
      refute Keyword.has_key?(pinned, :sockopts)
    end

    test "an IPv6-only name is pinned over IPv6, keeping implicit-TLS socket options" do
      answers = %{inet6: {:ok, [{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x25}]}}
      options = ssl_options("smtp.example.com")

      assert {:ok, pinned} = enforce(options, :personal, resolver: resolver(answers))

      assert pinned[:relay] == "2001:db8::25"
      assert :inet6 in pinned[:sockopts]
      assert pinned[:sockopts][:server_name_indication] == ~c"smtp.example.com"
      assert pinned[:sockopts][:verify] == :verify_peer
    end

    test "one internal address among public ones refuses the name" do
      answers = %{inet: {:ok, [{203, 0, 113, 25}, {10, 0, 0, 7}]}}

      assert {:error, {:smtp_endpoint_refused, :blocked_address}} =
               enforce(starttls_options("smtp.example.com"), :personal,
                 resolver: resolver(answers)
               )

      answers = %{inet: {:ok, [{203, 0, 113, 25}]}, inet6: {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]}}

      assert {:error, {:smtp_endpoint_refused, :blocked_address}} =
               enforce(starttls_options("smtp.example.com"), :personal,
                 resolver: resolver(answers)
               )
    end

    test "a name that does not resolve is refused rather than left to gen_smtp" do
      assert {:error, {:smtp_endpoint_refused, :unresolvable_host}} =
               enforce(starttls_options("nowhere.example.com"), :personal,
                 resolver: resolver(%{})
               )
    end

    test "every connect checks again, so a name that changes its answer is caught" do
      # DNS rebinding: a public answer for the first connect, an internal one
      # for the next.
      {:ok, agent} = Agent.start_link(fn -> [{203, 0, 113, 25}, {127, 0, 0, 1}] end)

      rebinding = fn _name, family ->
        if family == :inet,
          do: {:ok, [Agent.get_and_update(agent, fn [ip | rest] -> {ip, rest} end)]},
          else: {:error, :nxdomain}
      end

      options = starttls_options("rebind.example.com")

      assert {:ok, first} = enforce(options, :personal, resolver: rebinding)
      assert first[:relay] == "203.0.113.25"

      assert {:error, {:smtp_endpoint_refused, :blocked_address}} =
               enforce(options, :personal, resolver: rebinding)
    end

    test "a blank host is left alone — there is nothing to connect to" do
      for host <- [nil, ""] do
        options = starttls_options("x") |> Keyword.put(:relay, host)
        assert {:ok, ^options} = enforce(options, :personal, resolver: no_dns())
      end
    end
  end

  describe "policy_for/2" do
    test "a connection that carries an owner is personal, whatever the caller says" do
      creds = %{"owner_type" => "user", "owner_uuid" => Ecto.UUID.generate()}
      assert SmtpEndpointPolicy.policy_for(creds, :system) == :personal
    end

    test "an ownerless connection is system only when the caller says so" do
      assert SmtpEndpointPolicy.policy_for(%{}, :system) == :system
      assert SmtpEndpointPolicy.policy_for(%{"owner_uuid" => nil}, :system) == :system
      assert SmtpEndpointPolicy.policy_for(%{}, {:user, Ecto.UUID.generate()}) == :personal
      # An unknown owner gets the strict policy.
      assert SmtpEndpointPolicy.policy_for(%{}, nil) == :personal
      assert SmtpEndpointPolicy.policy_for(%{}, :any) == :personal
    end
  end

  describe "enabled?/0" do
    setup do
      original = Application.fetch_env(:phoenix_kit, :personal_smtp_policy)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:phoenix_kit, :personal_smtp_policy, value)
          :error -> Application.delete_env(:phoenix_kit, :personal_smtp_policy)
        end
      end)
    end

    test "off unless the host opts in" do
      Application.delete_env(:phoenix_kit, :personal_smtp_policy)
      refute SmtpEndpointPolicy.enabled?()

      for value <- [nil, false, :open] do
        Application.put_env(:phoenix_kit, :personal_smtp_policy, value)
        refute SmtpEndpointPolicy.enabled?()
      end
    end

    test "on for :restricted, and for any value it does not recognise" do
      for value <- [:restricted, true, :restrict, "restricted"] do
        Application.put_env(:phoenix_kit, :personal_smtp_policy, value)
        assert SmtpEndpointPolicy.enabled?(), "expected #{inspect(value)} to enable it"
      end
    end

    test "enforce/3 reads it when not told" do
      Application.put_env(:phoenix_kit, :personal_smtp_policy, :restricted)

      assert {:error, {:smtp_endpoint_refused, :blocked_address}} =
               SmtpEndpointPolicy.enforce(starttls_options("127.0.0.1"), :personal)

      Application.delete_env(:phoenix_kit, :personal_smtp_policy)
      options = starttls_options("127.0.0.1", 5432)
      assert {:ok, ^options} = SmtpEndpointPolicy.enforce(options, :personal)
    end
  end
end
