defmodule PhoenixKit.Integrations.Validators do
  @moduledoc """
  Real connection checks for providers that cannot be validated with a simple
  authenticated HTTP GET.

  `PhoenixKit.Integrations.do_validate/2` falls through to `:ok` for any provider
  that declares no validation. For the e-mail providers that meant "Test
  Connection" verified *nothing*: the connection was stamped `"connected"`
  without a single byte leaving the box, so an operator who pasted a wrong key
  or a bad SMTP password saw a green check and then a failing send. These
  validators close that gap.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Mailer

  @smtp_timeout 10_000

  @doc """
  Validates AWS SES credentials against the SES API itself.

  Asks SES for the account's send quota — the cheapest call that proves the
  credentials are real *and* authorised for SES *in this region*. Built as a raw
  `ExAws.Operation.Query`, so it needs no `ex_aws_ses` dependency.
  """
  @spec aws_ses(map()) :: :ok | {:error, String.t()}
  def aws_ses(data) do
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
      region: data["aws_region"]
    )
    |> case do
      {:ok, _quota} -> :ok
      {:error, reason} -> {:error, describe_aws_error(reason)}
    end
  rescue
    error ->
      Logger.warning("SES connection check failed: #{inspect(error)}")
      {:error, gettext("Could not reach AWS SES")}
  end

  @doc """
  Validates an SMTP relay by opening a real session and authenticating.

  The connection options come from `PhoenixKit.Mailer.swoosh_config_for/1`, so
  the check exercises exactly the transport (implicit TLS on 465, mandatory
  STARTTLS elsewhere when credentials are present) that a real send would use —
  one source of truth, no drift between "tested" and "sent".

  `auth: :always` is deliberate: with gen_smtp's default a relay that does not
  demand authentication would accept a wrong password and report success.
  """
  @spec smtp(map()) :: :ok | {:error, String.t()}
  def smtp(data) do
    case Mailer.swoosh_config_for(Map.put(data, "provider", "smtp")) do
      {:ok, {Swoosh.Adapters.SMTP, config}} ->
        config
        |> Keyword.merge(auth: :always, retries: 0, timeout: @smtp_timeout)
        |> open_smtp()

      {:error, {:invalid_smtp_port, port}} ->
        {:error, gettext("Invalid port: %{port}", port: inspect(port))}

      {:error, _other} ->
        {:error, gettext("Incomplete SMTP settings")}
    end
  end

  # `open/1` answers with `{:ok, socket}` or a THREE-element error tuple —
  # never `{:error, reason}`.
  defp open_smtp(options) do
    case :gen_smtp_client.open(options) do
      {:ok, socket} ->
        :gen_smtp_client.close(socket)
        :ok

      {:error, :bad_option, reason} ->
        {:error, describe_bad_option(reason)}

      {:error, _type, reason} ->
        {:error, describe_smtp_failure(reason)}
    end
  rescue
    error ->
      Logger.warning("SMTP connection check failed: #{inspect(error)}")
      {:error, gettext("Could not reach the SMTP server")}
  catch
    # gen_smtp signals auth/handshake problems by exiting the calling process.
    :exit, reason ->
      Logger.warning("SMTP connection check exited: #{inspect(reason)}")
      {:error, describe_smtp_failure(reason)}
  end

  # SES answers a bad key with 403 and an unknown key with 400; anything else is
  # a transport problem the operator can't act on beyond "unreachable".
  defp describe_aws_error({:http_error, status, _body}) when status in [400, 403],
    do: gettext("Invalid credentials")

  defp describe_aws_error({:http_error, status, _body}),
    do: gettext("Service error %{status}", status: status)

  defp describe_aws_error(_reason), do: gettext("Could not reach AWS SES")

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

      String.contains?(text, ["nxdomain", "econnrefused", "timeout", "ehostunreach"]) ->
        gettext("Could not reach the SMTP server")

      true ->
        gettext("SMTP server rejected the connection")
    end
  end
end
