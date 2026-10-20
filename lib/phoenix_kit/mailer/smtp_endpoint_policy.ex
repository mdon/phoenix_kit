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

  `nil`, `false` and `:open` mean off; any other value means on, so a typo
  fails closed rather than silently leaving personal connections unchecked.
  Website-wide (`:system`) connections are never affected.

  ## What is refused

  For a personal connection, with the policy on:

    * a port other than 25, 465, 587 or 2525 (`:blocked_port`);
    * a name that only means something inside a network — a bare name with no
      dot (`localhost`, `pgbouncer`), or one under `localhost`, `local`,
      `internal` or `home.arpa` (`:blocked_host`) — refused without a lookup;
    * a host that is, or resolves to, anything but a public address: loopback,
      private, carrier-grade NAT, link-local, unique-local, multicast,
      unspecified or reserved space, classified by
      `PhoenixKit.Modules.Storage.Endpoint.classify/1` (`:blocked_address`).
      A name is resolved for both IPv4 and IPv6, and **every** address it
      yields must be public;
    * a name that does not resolve (`:unresolvable_host`) — there is no
      checked address to connect to, and handing the name to the SMTP client
      would let it resolve the name again unchecked.

  Refusals come back as `{:error, {:smtp_endpoint_refused, reason}}`.

  ## Connect-time pinning

  The check runs right before each socket is opened — in
  `PhoenixKit.Integrations.Validators.smtp/2` (Test Connection, saved or not)
  and in `PhoenixKit.Mailer.swoosh_config_for/1` (every send through
  `deliver_via_integration/3`) — and the options it returns carry the checked
  address as the relay, so the SMTP client connects to exactly the address that
  was checked and never resolves the name itself. A name that answers with a
  public address at check time and an internal one at connect time (DNS
  rebinding) has no second lookup to exploit. TLS still verifies the
  certificate against the name the operator typed: the server-name indication
  and hostname check are built from the configured host, not the relay.

  Residual risk: the first address of the checked set is used (IPv4 preferred),
  with no fallback to the others — the same single attempt the client made
  with a name. A public address that forwards to an internal one (a relay the
  user controls) is outside what any address check can see.
  """

  alias PhoenixKit.Modules.Storage.Endpoint

  @allowed_ports [25, 465, 587, 2525]
  @internal_suffixes ~w(localhost local internal home.arpa)

  @type policy :: :system | :personal
  @type reason :: :blocked_port | :blocked_host | :blocked_address | :unresolvable_host

  @doc "Whether the host has turned the policy on (see the module doc)."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:phoenix_kit, :personal_smtp_policy) not in [nil, false, :open]
  end

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
      defaults to `:inet.getaddrs/2`.
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
           {:ok, ip} <- checked_address(host, opts) do
        {:ok, pin(options, ip)}
      else
        {:error, reason} -> {:error, {:smtp_endpoint_refused, reason}}
      end
    end
  end

  defp check_port(port) when port in @allowed_ports, do: :ok
  defp check_port(_port), do: {:error, :blocked_port}

  defp checked_address(host, opts) do
    name =
      host
      |> String.trim()
      |> String.trim_leading("[")
      |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(name)) do
      {:ok, ip} -> all_public([ip])
      {:error, _} -> checked_name(name, opts)
    end
  end

  defp checked_name(name, opts) do
    name = name |> String.downcase() |> String.trim_trailing(".")

    if internal_name?(name) do
      {:error, :blocked_host}
    else
      case resolve(name, Keyword.get(opts, :resolver, &:inet.getaddrs/2)) do
        [] -> {:error, :unresolvable_host}
        ips -> all_public(ips)
      end
    end
  end

  defp internal_name?(name) do
    not String.contains?(name, ".") or
      Enum.any?(@internal_suffixes, &(name == &1 or String.ends_with?(name, "." <> &1)))
  end

  # IPv4 first, so it is the one pinned when a name has both.
  defp resolve(name, resolver) do
    charlist = String.to_charlist(name)

    Enum.flat_map([:inet, :inet6], fn family ->
      case resolver.(charlist, family) do
        {:ok, ips} -> ips
        {:error, _reason} -> []
      end
    end)
  end

  defp all_public([first | _] = ips) do
    if Enum.all?(ips, &(Endpoint.classify(&1) == :public)),
      do: {:ok, first},
      else: {:error, :blocked_address}
  end

  # gen_smtp connects to the relay string as given; an address literal is never
  # looked up. An IPv6 one needs the `inet6` socket option, which gen_smtp
  # passes through for both plain and implicit-TLS sockets.
  defp pin(options, ip) do
    options = Keyword.replace!(options, :relay, ip |> :inet.ntoa() |> to_string())

    if tuple_size(ip) == 8,
      do: Keyword.update(options, :sockopts, [:inet6], &[:inet6 | &1]),
      else: options
  end

  defp owned?(creds), do: not blank?(creds["owner_uuid"])

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
