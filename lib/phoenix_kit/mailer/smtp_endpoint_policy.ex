defmodule PhoenixKit.Mailer.SmtpEndpointPolicy do
  @moduledoc """
  Where a personal SMTP connection may make the server connect to.

  An SMTP connection names a host and a port, and both "Test Connection" and
  every send open a socket to them from the server. For a website-wide
  connection that is an admin's choice. A personal connection (one owned by a
  user, `{:user, uuid}` or any other typed owner) is set by whoever was allowed
  to add one — and, left unchecked, lets that user make the server connect to
  internal hosts: the database, a connection pooler, a cache, cloud metadata.
  The SMTP banner or the error that comes back is enough to probe the internal
  network.

  ## Turning it on

  Off by default — personal connections then connect exactly as they always
  did. A host enables it in its config:

      config :phoenix_kit, :personal_smtp_policy, :restricted

  `nil`, `false` and `:open` mean off; **any other value means on**, so a typo
  fails closed rather than silently leaving personal connections unchecked.
  That includes strings: a value read with `System.get_env/1` is a string, and
  `"false"` turns the policy on — map an environment variable to an atom in
  `config/runtime.exs` yourself. Website-wide (`:system`) connections are never
  affected.

  ## What is refused

  For a personal connection, with the policy on:

    * a port other than 25, 465, 587 or 2525 (`:blocked_port`);
    * a host the server must not connect to (`:blocked_host`):
      * a name that only means something inside a network — a bare name with
        no dot (`localhost`, `pgbouncer`), or one under `localhost`, `local`,
        `internal` or `home.arpa` — refused without a lookup;
      * a host that is, or resolves to, anything but a public address:
        loopback, private, carrier-grade NAT, link-local, unique-local,
        multicast, unspecified or reserved space, classified by
        `PhoenixKit.Modules.Storage.Endpoint.classify/1`. A name is resolved
        for both IPv4 and IPv6, and **every** address it yields must be public;
      * a name that does not resolve, or not within the connection's timeout —
        there is no checked address to connect to, and handing the name to the
        SMTP client would let it resolve the name again unchecked.

  The host cases share one reason and one message on purpose: telling "does
  not resolve" apart from "resolves to an internal address" would let a user
  find out which names exist in the server's internal DNS.

  Refusals come back as `{:error, {:smtp_endpoint_refused, reason}}`;
  `message/1` turns the reason into the sentence to show.

  ## Connect-time pinning

  The check runs right before each socket is opened — in
  `PhoenixKit.Integrations.Validators.smtp/2` (Test Connection, saved or not)
  and in `PhoenixKit.Mailer.swoosh_config_for/1` (every send through
  `deliver_via_integration/3`) — and the options it returns carry the checked
  address as the relay, so the SMTP client connects to exactly the address that
  was checked and never resolves the name itself. A name that answers with a
  public address at check time and an internal one at connect time (DNS
  rebinding) has no second lookup to exploit. The TLS handshake still names the
  host the operator typed: the certificate is verified against it, and it is
  sent as the server-name indication even when certificates are not verified.

  The lookup is bounded by the connection's `timeout` (5 s when none is set);
  IPv4 and IPv6 are asked at the same time, and a family that does not answer
  in time counts as no addresses.

  Residual risk: the first address of the checked set is used (IPv4 preferred),
  with no fallback to the others — the same single attempt the client made
  with a name. A public address that forwards to an internal one (a relay the
  user controls) is outside what any address check can see.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Storage.Endpoint

  @allowed_ports [25, 465, 587, 2525]
  @internal_suffixes ~w(localhost local internal home.arpa)
  # gen_smtp's own connect timeout, used when the connection sets none.
  @default_lookup_timeout 5_000

  @type policy :: :system | :personal
  @type reason :: :blocked_port | :blocked_host

  @doc "Whether the host has turned the policy on (see the module doc)."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:phoenix_kit, :personal_smtp_policy) not in [nil, false, :open]
  end

  @doc """
  The sentence to show a person for a refusal reason — for a caller of
  `PhoenixKit.Mailer.deliver_via_integration/3` that got
  `{:error, {:smtp_endpoint_refused, reason}}`, and for Test Connection.
  """
  @spec message(reason()) :: String.t()
  def message(:blocked_port),
    do: gettext("Personal SMTP connections may only use ports 25, 465, 587 or 2525")

  def message(:blocked_host), do: gettext("The SMTP host must resolve to a public address")

  @doc """
  The policy for a connection, from its credentials and the owner the caller
  acted as.

  A connection whose credentials carry an `owner_uuid` is personal whatever the
  caller says. One without is `:system` only when the caller says `:system`;
  any other owner — a user, `:any`, none at all — gets the strict policy.
  """
  @spec policy_for(map(), term()) :: policy()
  def policy_for(creds, owner) when is_map(creds) do
    if owner == :system and not owned?(creds), do: :system, else: :personal
  end

  @doc """
  Checks the built SMTP options (`PhoenixKit.Mailer.SmtpTransport.config/1`)
  under `policy`, returning them with the relay pinned to the checked address.

  Returns the options untouched for a `:system` connection, when the policy is
  off, and when no host is set (there is nothing to connect to). Options:

    * `:enabled` — overrides `enabled?/0` (tests).
    * `:resolver` — `(charlist, :inet | :inet6 -> {:ok, [ip]} | {:error, _})`,
      defaults to `:inet.getaddrs/3` with the lookup timeout. Whatever the
      resolver, an answer that does not come within the timeout is not waited
      for.
  """
  @spec enforce(keyword(), policy(), keyword()) ::
          {:ok, keyword()} | {:error, {:smtp_endpoint_refused, reason()}}
  def enforce(options, policy, opts \\ [])

  def enforce(options, :system, _opts), do: {:ok, options}

  def enforce(options, :personal, opts) do
    if Keyword.get_lazy(opts, :enabled, &enabled?/0),
      do: restrict(options, opts),
      else: {:ok, options}
  end

  defp restrict(options, opts) do
    host = options[:relay]

    if blank?(host) do
      {:ok, options}
    else
      with :ok <- check_port(options[:port]),
           {:ok, ip, name} <- checked_address(host, lookup_timeout(options), opts) do
        {:ok, pin(options, ip, name)}
      else
        {:error, reason} -> {:error, {:smtp_endpoint_refused, reason}}
      end
    end
  end

  defp check_port(port) when port in @allowed_ports, do: :ok
  defp check_port(_port), do: {:error, :blocked_port}

  defp lookup_timeout(options) do
    case options[:timeout] do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_lookup_timeout
    end
  end

  # `{:ok, ip, name}` — `name` is the normalized host name, or `nil` for a
  # literal address.
  defp checked_address(host, timeout, opts) do
    trimmed =
      host
      |> String.trim()
      |> String.trim_leading("[")
      |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(trimmed)) do
      {:ok, ip} ->
        with {:ok, ip} <- all_public([ip]), do: {:ok, ip, nil}

      {:error, _} ->
        name = trimmed |> String.downcase() |> String.trim_trailing(".")

        with {:ok, ip} <- checked_name(name, timeout, opts), do: {:ok, ip, name}
    end
  end

  defp checked_name(name, timeout, opts) do
    if internal_name?(name) do
      {:error, :blocked_host}
    else
      resolver = Keyword.get(opts, :resolver, &:inet.getaddrs(&1, &2, timeout))

      case resolve(name, resolver, timeout) do
        [] -> {:error, :blocked_host}
        ips -> all_public(ips)
      end
    end
  end

  defp internal_name?(name) do
    not String.contains?(name, ".") or
      Enum.any?(@internal_suffixes, &(name == &1 or String.ends_with?(name, "." <> &1)))
  end

  # Both families at once, each bounded; IPv4 first in the result, so it is the
  # one pinned when a name has both.
  defp resolve(name, resolver, timeout) do
    charlist = String.to_charlist(name)

    [:inet, :inet6]
    |> Task.async_stream(fn family -> resolver.(charlist, family) end,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, ips}} when is_list(ips) -> ips
      _no_answer -> []
    end)
  end

  defp all_public([first | _] = ips) do
    if Enum.all?(ips, &(Endpoint.classify(&1) == :public)),
      do: {:ok, first},
      else: {:error, :blocked_host}
  end

  # gen_smtp connects to the relay string as given; an address literal is never
  # looked up. An IPv6 one needs the `inet6` socket option, which gen_smtp
  # passes through for both plain and implicit-TLS sockets.
  defp pin(options, ip, name) do
    options
    |> Keyword.replace!(:relay, ip |> :inet.ntoa() |> to_string())
    |> put_sni(name)
    |> put_inet6(ip)
  end

  defp put_inet6(options, ip) when tuple_size(ip) == 8,
    do: Keyword.update(options, :sockopts, [:inet6], &[:inet6 | &1])

  defp put_inet6(options, _ip), do: options

  # OTP derives SNI from a hostname it is given, but not from an address. With
  # the relay pinned to an address, a TLS option list that carried no SNI of its
  # own (certificate verification off) would go out with none; give it the
  # typed name. `SmtpTransport` builds TLS options in `sockopts` for implicit
  # TLS and in `tls_options` for STARTTLS; a plaintext relay has neither.
  defp put_sni(options, nil), do: options

  defp put_sni(options, name) do
    key = if options[:ssl] == true, do: :sockopts, else: :tls_options

    case Keyword.fetch(options, key) do
      {:ok, tls} when is_list(tls) ->
        Keyword.replace!(
          options,
          key,
          Keyword.put_new(tls, :server_name_indication, String.to_charlist(name))
        )

      _ ->
        options
    end
  end

  defp owned?(creds), do: not blank?(creds["owner_uuid"])

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
