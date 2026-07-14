defmodule PhoenixKit.Integrations.Validators do
  @moduledoc """
  Real connection checks for providers that cannot be validated with a simple
  authenticated HTTP GET.

  `PhoenixKit.Integrations.do_validate/2` falls through to `:ok` for any provider
  that declares no validation. For the e-mail providers that meant "Test
  Connection" verified *nothing*: the connection was stamped `"connected"`
  without a single byte leaving the box, so an operator who pasted a wrong key or
  a bad SMTP password saw a green check and then a failing send.

  A check that always says yes is worse than no check — but so is one that says
  no when the configuration is fine. These validators are therefore careful in
  both directions:

    * a relay that authenticates by IP and offers no `AUTH` verb passes (the
      credentials are simply unused — sending works, so the check is green);
    * SES credentials scoped to `ses:SendEmail` only — the least-privilege policy
      AWS itself recommends — pass, even though they cannot read the send quota.

  Every check runs through `PhoenixKit.Integrations.Probe`, which bounds it with
  a hard deadline and isolates it from the caller — the libraries underneath
  bound neither themselves nor their crashes, and both call sites are LiveView
  callbacks.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Integrations.Probe
  alias PhoenixKit.Mailer.SmtpTransport

  @doc """
  Validates AWS SES credentials against the SES API itself.

  Asks SES for the account's send quota — the cheapest call that proves the
  credentials are real. Built as a raw `ExAws.Operation.Query`, so it needs no
  `ex_aws_ses` dependency.

  The endpoint host is passed explicitly rather than left to ExAws, whose region
  resolution is a hard-coded prefix allowlist (`~r/^(us|eu|af|ap|sa|ca|me)-.../`)
  that silently yields *no host at all* for newer regions such as `il-central-1`
  — while the send path (`Swoosh.Adapters.AmazonSES`) simply interpolates the
  region and works. Validate and send must resolve the same endpoint.
  """
  @spec aws_ses(map()) :: :ok | {:error, String.t()}
  def aws_ses(data) do
    region = data["aws_region"]

    cond do
      blank?(data["access_key"]) or blank?(data["secret_key"]) ->
        {:error, gettext("Incomplete credentials")}

      # ExAws would otherwise default a blank region to us-east-1 and happily
      # report success, while the send path builds "email..amazonaws.com" from
      # the same blank region and raises.
      blank?(region) ->
        {:error, gettext("Region is required")}

      true ->
        Probe.run(fn -> request_send_quota(region, data) end)
    end
  end

  @doc """
  Validates an SMTP relay by opening a real session and authenticating.

  The connection options come from `PhoenixKit.Mailer.SmtpTransport.config/1`, so
  the check exercises exactly the transport a real send uses — one source of
  truth, no drift between "tested" and "sent".

  `auth: :always` is deliberate: with gen_smtp's default the AUTH exchange is
  attempted but its failure is tolerated, so a wrong password would still open a
  session and the check would pass. A relay that advertises no `AUTH` verb at all
  is a different case, and is treated as a pass — see the module doc.
  """
  @spec smtp(map()) :: :ok | {:error, String.t()}
  def smtp(data) do
    case SmtpTransport.config(data) do
      {:ok, options} ->
        Probe.run(fn -> open_smtp(options) end)

      {:error, {:invalid_smtp_port, port}} ->
        {:error, gettext("Invalid port: %{port}", port: inspect(port))}

      {:error, :no_ca_store} ->
        {:error,
         gettext("No system CA certificates found, so the relay's certificate cannot be verified")}
    end
  end

  # --- SMTP -----------------------------------------------------------------

  defp open_smtp(options) do
    case :gen_smtp_client.open(Keyword.put(options, :auth, :always)) do
      {:ok, socket} ->
        :gen_smtp_client.close(socket)
        :ok

      # The relay offers no AUTH verb — it authenticates by IP, or not at all.
      # The credentials are unused, a real send works, and `username`/`password`
      # are required fields the operator had to fill in with something. A red
      # cross here would be a lie about a working relay.
      {:error, _type, {:missing_requirement, _host, :auth}} ->
        Logger.info("SMTP relay advertises no AUTH; credentials are unused by this relay")
        :ok

      {:error, :bad_option, reason} ->
        {:error, describe_bad_option(reason)}

      {:error, _type, reason} ->
        {:error, describe_smtp_failure(reason)}
    end
  rescue
    # gen_smtp calls to_binary/1 on the username, which has no clause for nil —
    # reachable through the pre-save "test what you typed" probe, which does not
    # go through the credential gate.
    FunctionClauseError ->
      {:error, gettext("Incomplete SMTP settings")}

    error ->
      Logger.warning("SMTP connection check failed: #{inspect(error)}")
      {:error, gettext("Could not reach the SMTP server")}
  catch
    :exit, reason ->
      Logger.warning("SMTP connection check exited: #{inspect(reason)}")
      {:error, describe_smtp_failure(reason)}
  end

  defp describe_bad_option(reason)
       when reason in [:no_relay, :no_credentials, :invalid_port],
       do: gettext("Incomplete SMTP settings")

  defp describe_bad_option(_reason), do: gettext("Invalid SMTP settings")

  defp describe_smtp_failure(reason) do
    text = reason |> inspect() |> String.downcase()

    cond do
      # gen_smtp reports a rejected login as {:permanent_failure, host, :auth_failed}
      String.contains?(text, ["auth_failed", "535", "authentication", "not authenticated"]) ->
        gettext("Invalid credentials")

      String.contains?(text, ["tls_failed", "ssl_not_started"]) ->
        gettext("TLS handshake failed")

      String.contains?(text, ["nxdomain", "econnrefused", "timeout", "ehostunreach"]) ->
        gettext("Could not reach the SMTP server")

      true ->
        gettext("SMTP server rejected the connection")
    end
  end

  # --- SES ------------------------------------------------------------------

  defp request_send_quota(region, data) do
    case send_quota_request(region, data) do
      # Never call credentials invalid on a single 403. AWS briefly answers a
      # *correct* request with SignatureDoesNotMatch right after it has rejected
      # a bad signature from the same key — which is exactly the flow an operator
      # produces by pasting a wrong key, fixing it, and pressing Test again.
      # Telling them their good keys are invalid sends them off to reissue
      # credentials that were never the problem. Confirm before accusing.
      {:invalid, _} ->
        Process.sleep(700)

        case send_quota_request(region, data) do
          {:invalid, _} -> {:error, gettext("Invalid credentials")}
          confirmed -> confirmed
        end

      result ->
        result
    end
  end

  defp send_quota_request(region, data) do
    operation = %ExAws.Operation.Query{
      action: :get_send_quota,
      path: "/",
      params: %{"Action" => "GetSendQuota", "Version" => "2010-12-01"},
      service: :ses,
      parser: fn response, _action -> response end
    }

    operation
    |> ExAws.request(
      access_key_id: data["access_key"],
      secret_access_key: data["secret_key"],
      region: region,
      host: "email.#{region}.amazonaws.com",
      # ExAws retries transport errors ten times with backoff by default; an
      # unreachable endpoint would block for minutes. Two attempts survives a
      # single blip (SES throttles GetSendQuota aggressively) and still stays
      # well inside the outer deadline.
      retries: [max_attempts: 2],
      http_opts: [recv_timeout: 5_000, connect_timeout: 5_000]
    )
    |> case do
      {:ok, _quota} -> :ok
      {:error, reason} -> interpret_ses_error(reason)
    end
  rescue
    error ->
      Logger.warning("SES connection check failed: #{inspect(error)}")
      {:error, gettext("Could not reach AWS SES")}
  end

  defp interpret_ses_error({:http_error, _status, response}) do
    case aws_error_code(response) do
      code
      when code in ~w(SignatureDoesNotMatch InvalidClientTokenId UnrecognizedClientException) ->
        {:invalid, code}

      # SES throttles GetSendQuota hard (~1 request/second). Reporting a
      # throttle as "invalid credentials" would send an operator off to reissue
      # perfectly good keys — observed live while testing this very validator.
      code
      when code in ~w(Throttling ThrottlingException RequestExpired
                      ServiceUnavailable InternalFailure) ->
        {:error, gettext("AWS SES is busy — try again in a moment")}

      # The credentials are valid and merely lack `ses:GetSendQuota` — which is
      # exactly what AWS's own least-privilege guidance produces (grant only
      # ses:SendEmail / ses:SendRawEmail). Sending works. Reporting "invalid
      # credentials" here would put a permanent red cross on a correctly
      # configured integration and teach operators to ignore the check.
      "AccessDenied" <> _ ->
        Logger.info("SES credentials valid but not authorised for GetSendQuota; sending may work")
        :ok

      nil ->
        {:error, gettext("Could not reach AWS SES")}

      code ->
        {:error, gettext("AWS SES error: %{code}", code: code)}
    end
  end

  defp interpret_ses_error(_reason), do: {:error, gettext("Could not reach AWS SES")}

  # The Query API answers with an XML body carrying an <Code> element.
  defp aws_error_code(%{body: body}) when is_binary(body), do: aws_error_code(body)

  defp aws_error_code(body) when is_binary(body) do
    case Regex.run(~r{<Code>([^<]+)</Code>}, body) do
      [_, code] -> code
      _ -> nil
    end
  end

  defp aws_error_code(_), do: nil

  # --- shared ---------------------------------------------------------------

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
