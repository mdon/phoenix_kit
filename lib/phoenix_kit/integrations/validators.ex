defmodule PhoenixKit.Integrations.Validators do
  @moduledoc """
  Real connection checks for providers that cannot be validated with a simple
  authenticated HTTP GET.

  `PhoenixKit.Integrations` falls through to `:ok` for any provider that declares
  no validation. For the e-mail providers that meant "Test Connection" verified
  *nothing*: the connection was stamped `"connected"` without a single byte
  leaving the box, so an operator who pasted a wrong key or a bad SMTP password
  saw a green check and then a failing send.

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
  alias PhoenixKit.Utils.Number

  @http_timeout 15_000

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
  @spec aws_ses(map()) :: :ok | {:ok, String.t()} | {:error, String.t()}
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
  @spec smtp(map()) :: :ok | {:ok, String.t()} | {:error, String.t()}
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
    probe_options =
      options
      |> Keyword.put(:auth, :always)
      # gen_smtp retries a temporarily-failing relay once by default, which doubles
      # the time to a verdict and can push a slow failure past our deadline — the
      # operator would be told "did not respond in time" instead of what went wrong.
      # A real send still wants the retry; a check does not.
      |> Keyword.put(:retries, 0)

    case :gen_smtp_client.open(probe_options) do
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
    # go through the credential gate. It is a wide net, so it leaves a trace: a
    # FunctionClauseError from anywhere else must not vanish as "incomplete".
    error in FunctionClauseError ->
      Logger.warning("SMTP connection check raised FunctionClauseError: #{inspect(error)}")
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

  @doc false
  # `requester` is injectable so the confirm-retry — the behaviour that keeps a valid
  # key from being reported invalid — can be tested without talking to AWS.
  def request_send_quota(region, data, requester \\ &send_quota_request/2) do
    case requester.(region, data) do
      # Never call credentials invalid on a single 403. AWS briefly answers a
      # *correct* request with SignatureDoesNotMatch right after it has rejected
      # a bad signature from the same key — which is exactly the flow an operator
      # produces by pasting a wrong key, fixing it, and pressing Test again.
      # Telling them their good keys are invalid sends them off to reissue
      # credentials that were never the problem. Confirm before accusing.
      {:invalid, _} ->
        # A full second, not less: SES throttles GetSendQuota at about one request
        # per second, and the confirm-retry doubles our rate against it. Come back
        # too soon and the second call answers Throttling, which reports a genuinely
        # invalid key as "AWS SES is busy".
        Process.sleep(1_000)

        case requester.(region, data) do
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
      #
      # All three keys are mandatory. ExAws merges this override with `Map.merge`,
      # so the list REPLACES the default wholesale — pass `max_attempts` alone and
      # the backoff keys vanish, leaving `ExAws.Request.backoff/2` to evaluate
      # `nil * :math.pow(2, attempt)`. It raises, the rescue below swallows it, and
      # the check silently performs no retries at all.
      retries: [max_attempts: 2, base_backoff_in_ms: 10, max_backoff_in_ms: 1_000],
      http_opts: [recv_timeout: 5_000, connect_timeout: 5_000]
    )
    |> case do
      {:ok, %{body: body}} ->
        case format_quota_note(body) do
          nil -> :ok
          note -> {:ok, note}
        end

      {:error, reason} ->
        interpret_ses_error(reason)
    end
  rescue
    error ->
      Logger.warning("SES connection check failed: #{inspect(error)}")
      {:error, gettext("Could not reach AWS SES")}
  catch
    # hackney reaches its connection pool through GenServer.call, which exits
    # rather than raising — `rescue` alone does not see it.
    :exit, reason ->
      Logger.warning("SES connection check exited: #{inspect(reason)}")
      {:error, gettext("Could not reach AWS SES")}
  end

  @doc false
  # Pure: an AWS error payload in, an operator-facing verdict out. Public so the
  # mapping can be tested against real SES bodies without a network round trip.
  def interpret_ses_error({:http_error, _status, response}) do
    case aws_error_code(response) do
      code
      when code in ~w(SignatureDoesNotMatch InvalidClientTokenId UnrecognizedClientException
                      InvalidAccessKeyId ExpiredToken TokenRefreshRequired) ->
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
      # ses:SendEmail / ses:SendRawEmail). Reporting "invalid credentials" here
      # would put a permanent red cross on a correctly configured integration and
      # teach operators to ignore the check.
      #
      # But this is NOT proof that the key can send: a signature valid for the
      # wrong AWS account also lands here. So it passes with the truth attached
      # rather than a bare green tick — the note reaches the operator, not just
      # the log.
      "AccessDenied" <> _ ->
        {:ok,
         gettext(
           "Credentials are valid, but not authorised for GetSendQuota — sending was not verified"
         )}

      nil ->
        {:error, gettext("Could not reach AWS SES")}

      code ->
        {:error, gettext("AWS SES error: %{code}", code: code)}
    end
  end

  def interpret_ses_error(_reason), do: {:error, gettext("Could not reach AWS SES")}

  # The Query API answers with an XML body carrying an <Code> element.
  defp aws_error_code(%{body: body}) when is_binary(body), do: aws_error_code(body)

  defp aws_error_code(body) when is_binary(body) do
    case Regex.run(~r{<Code>([^<]+)</Code>}, body) do
      [_, code] -> code
      _ -> nil
    end
  end

  defp aws_error_code(_), do: nil

  @doc false
  # Pure: an XML GetSendQuota body in, a compact operator-facing note out (or
  # `nil` if the body doesn't have the shape we expect — the credentials are
  # still good, we just have nothing to add). Public so the parsing can be
  # tested against real SES bodies without a network round trip.
  def format_quota_note(body) when is_binary(body) do
    with max when not is_nil(max) <- quota_tag(body, "Max24HourSend"),
         sent when not is_nil(sent) <- quota_tag(body, "SentLast24Hours"),
         rate when not is_nil(rate) <- quota_tag(body, "MaxSendRate") do
      # -1 signifies an unlimited quota — AWS's own convention for accounts
      # with no daily cap.
      max_text = if max == -1.0, do: gettext("unlimited"), else: Number.format(round(max))

      gettext("Quota: %{sent} / %{max} sent last 24h · max %{rate}/s",
        sent: Number.format(round(sent)),
        max: max_text,
        rate: Number.format(round(rate))
      )
    else
      _ -> nil
    end
  end

  def format_quota_note(_body), do: nil

  defp quota_tag(body, tag) do
    with [_, value] <- Regex.run(~r{<#{tag}>([^<]+)</#{tag}>}, body),
         {float, _rest} <- Float.parse(value) do
      float
    else
      _ -> nil
    end
  end

  # --- Brevo ------------------------------------------------------------

  @doc """
  Validates a Brevo API key against the account endpoint, and reports the
  remaining credits.

  Brevo authenticates with a bare `api-key` header (no `Bearer` prefix), and
  `GET /v3/account` doubles as the cheapest authenticated call and the only
  one that tells the operator anything beyond "the key works" — the plan's
  remaining send credits, which is exactly what silently runs out mid-campaign.
  """
  @spec brevo_api(map()) :: :ok | {:ok, String.t()} | {:error, String.t()}
  def brevo_api(data) do
    api_key = data["api_key"]

    if blank?(api_key) do
      {:error, gettext("No credentials configured")}
    else
      request_account(api_key)
    end
  end

  defp request_account(api_key) do
    case Req.get("https://api.brevo.com/v3/account",
           headers: [{"api-key", api_key}],
           receive_timeout: @http_timeout
         ) do
      {:ok, %{status: 200, body: body}} ->
        case format_credits_note(body) do
          nil -> :ok
          note -> {:ok, note}
        end

      {:ok, %{status: 401}} ->
        {:error, gettext("Invalid credentials")}

      {:ok, %{status: 403}} ->
        {:error, gettext("Access denied")}

      {:ok, %{status: status}} ->
        {:error, gettext("Brevo error %{status}", status: status)}

      {:error, reason} ->
        Logger.warning("Brevo connection check failed: #{inspect(reason)}")
        {:error, gettext("Could not reach Brevo")}
    end
  end

  @doc false
  # Pure: a decoded /v3/account JSON body in, a compact operator-facing note
  # out (or `nil` if there is no usable plan info). Public so the parsing can
  # be tested against real Brevo bodies without a network round trip.
  def format_credits_note(%{"plan" => plan}) when is_list(plan) and plan != [] do
    case plan |> Enum.map(&format_plan_entry/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      entries -> gettext("Plan: %{entries}", entries: Enum.join(entries, "; "))
    end
  end

  def format_credits_note(_body), do: nil

  defp format_plan_entry(%{"type" => type} = entry) when is_binary(type) do
    entry
    |> Map.get("credits")
    |> credits_text(type)
    |> with_reset_date(entry["endDate"])
  end

  defp format_plan_entry(_entry), do: nil

  defp credits_text(credits, type) when is_number(credits) do
    gettext("%{type} · %{credits} credits left",
      type: type,
      credits: Number.format(round(credits))
    )
  end

  defp credits_text(_credits, type), do: type

  defp with_reset_date(text, end_date) do
    case reset_date(end_date) do
      nil -> text
      date -> gettext("%{text} · resets %{date}", text: text, date: date)
    end
  end

  defp reset_date(end_date) when is_integer(end_date) do
    case DateTime.from_unix(end_date) do
      {:ok, datetime} -> Date.to_iso8601(DateTime.to_date(datetime))
      {:error, _reason} -> nil
    end
  end

  defp reset_date(_end_date), do: nil

  # --- shared ---------------------------------------------------------------

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
