defmodule PhoenixKit.Mailer.SmtpTransport do
  @moduledoc """
  Builds the gen_smtp/Swoosh connection options for an SMTP integration.

  Extracted so that *sending* and *"Test Connection"* are driven by literally the
  same options — a check that connects differently from the sender is a check
  that can lie in either direction. It is a pure function of the credentials map
  and depends on nothing else in the tree (in particular not on
  `PhoenixKit.Integrations`, which would otherwise close a
  Integrations → Validators → Mailer → Integrations cycle).

  ## TLS

  gen_smtp supplies **no** TLS options of its own, and OTP's `:ssl` now defaults
  to `verify: :verify_peer` with no CA store. Left alone, that means:

    * implicit TLS (465, `ssl: true`) dies on connect with
      `{:options, :incompatible, [verify: :verify_peer, cacerts: :undefined]}`;
    * STARTTLS (`tls: :always`) fails the handshake with `:tls_failed`.

  So the options below are load-bearing, not decoration. They ride on `sockopts`
  for implicit TLS (gen_smtp hands those straight to `:ssl.connect/4`) and on
  `tls_options` for STARTTLS.

  Note that passing `tls_options` *replaces* gen_smtp's default
  `[{versions, ['tlsv1', 'tlsv1.1', 'tlsv1.2']}]` wholesale (it merges with
  `lists:ukeymerge/3`). That is deliberate: we take OTP's defaults, which drop
  the long-dead TLS 1.0/1.1 and allow TLS 1.3.

  ## Certificate verification is not optional when credentials are on the wire

  If no CA store can be found we refuse to build a config for a relay that
  expects a password (`{:error, :no_ca_store}`) rather than silently falling back
  to `verify: :verify_none` — an unauthenticated TLS peer can present any
  certificate, terminate the connection and harvest the AUTH exchange. A relay
  that takes no credentials has nothing to protect, so it degrades instead.
  """

  require Logger

  @doc """
  Returns `{:ok, options}` for gen_smtp/`Swoosh.Adapters.SMTP`, or `{:error, reason}`.

  Reasons: `{:invalid_smtp_port, term}`, `:no_ca_store`.
  """
  @spec config(map()) :: {:ok, keyword()} | {:error, term()}
  def config(creds) when is_map(creds), do: config(creds, cacerts())

  @doc """
  Same as `config/1`, with the trusted CA store supplied explicitly.

  The options are a pure function of the credentials and the CA store; `config/1`
  simply reads the store from the system. Passing it in makes the fail-closed
  branch — no CA store, credentials on the wire — reachable from a test.
  """
  @spec config(map(), [binary()] | [tuple()]) :: {:ok, keyword()} | {:error, term()}
  def config(creds, cacerts) when is_map(creds) and is_list(cacerts) do
    with {:ok, port} <- parse_port(creds["port"]),
         {:ok, transport} <- transport(port, creds, cacerts) do
      base = [
        relay: creds["host"],
        port: port,
        username: creds["username"],
        password: creds["password"],
        # An explicitly configured smarthost is an address, not a domain to
        # resolve: gen_smtp would otherwise MX-look-up the relay and connect to
        # whatever the MX records point at, while we pin SNI and the hostname
        # check to the configured name — a guaranteed certificate mismatch.
        no_mx_lookups: true
      ]

      {:ok, base ++ transport}
    end
  end

  # Setup fields are typed `:number` but travel through LiveView form params and
  # JSONB storage as strings — normalize either shape. A port we cannot parse
  # would silently become gen_smtp's default (25) and relay to an unintended
  # server, so it is an error, not a fallback.
  defp parse_port(port) when is_integer(port), do: {:ok, port}

  defp parse_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {int, _} -> {:ok, int}
      :error -> {:error, {:invalid_smtp_port, port}}
    end
  end

  defp parse_port(port), do: {:error, {:invalid_smtp_port, port}}

  # Port 465 = implicit TLS (SMTPS). gen_smtp decides the protocol solely from
  # the `ssl` option (`gen_smtp_client.erl` — `ssl: true` → ssl socket, else
  # plaintext tcp); `tls` only drives a STARTTLS upgrade *after* a plaintext
  # connect, so `tls: :always` on 465 would open plaintext to an SMTPS port.
  defp transport(465, creds, cacerts) do
    case tls_options(creds, cacerts) do
      {:ok, tls_opts} -> {:ok, [ssl: true, sockopts: tls_opts]}
      {:error, _} = error -> error
    end
  end

  defp transport(_port, creds, cacerts) do
    case tls_options(creds, cacerts) do
      {:ok, tls_opts} ->
        if credentials?(creds) do
          # Credentials on the wire: mandatory, verified STARTTLS. Fail closed
          # rather than let a stripped STARTTLS capability downgrade us to
          # plaintext.
          {:ok, [tls: :always, tls_options: tls_opts]}
        else
          # Nothing to protect — still offer verified TLS, but do not refuse a
          # relay that has none.
          {:ok, [tls: :if_available, tls_options: tls_opts]}
        end

      {:error, _} = error ->
        error
    end
  end

  defp tls_options(creds, cacerts) do
    case cacerts do
      [] ->
        if credentials?(creds) do
          {:error, :no_ca_store}
        else
          Logger.warning(
            "No system CA certificates found — SMTP TLS certificate verification is disabled " <>
              "for this credential-less relay. Install a CA bundle to enable it."
          )

          {:ok, [verify: :verify_none]}
        end

      cacerts ->
        {:ok,
         [
           verify: :verify_peer,
           # NOT optional, and not a copy-paste default: gen_smtp's own socket
           # layer ships `{depth, 0}` (smtp_socket.erl:43,52) and merges it into
           # whatever we pass. Depth 0 means "no intermediate CAs allowed", so
           # every real certificate chain (leaf + intermediate) fails
           # verification and the handshake dies with `:tls_failed`. Verified
           # against a live relay: omit this key and the connection fails 4/4;
           # set it to anything >= 1 and it succeeds. 10 is the conventional
           # ceiling for a chain.
           depth: 10,
           cacerts: cacerts,
           server_name_indication: sni(creds["host"]),
           customize_hostname_check: [
             match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
           ]
         ]}
    end
  end

  defp sni(host) when is_binary(host) and host != "", do: to_charlist(host)
  defp sni(_host), do: :disable

  defp cacerts do
    :public_key.cacerts_get()
  rescue
    _ -> []
  end

  defp credentials?(creds), do: not (blank?(creds["username"]) and blank?(creds["password"]))

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
