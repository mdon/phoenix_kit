defmodule PhoenixKit.API.Confirm.Token do
  @moduledoc """
  The confirmation code string of a dangerous API operation: `ct_<row uuid>_<mac>`.

  `mac` is the first 24 bytes of `HMAC-SHA256(key, "api-confirm:" <> uuid)`, base64url
  without padding (32 characters), where `key` is derived from the host's
  `secret_key_base`. The code proves nothing by itself: the row it names says
  what it was issued for, and the executor checks that against the request. Anyone who
  does not know the secret cannot make a code for a row.

  The secret is looked up as `config :phoenix_kit, :secret_key_base`, then the parent
  endpoint's, then core's own endpoint's (the same sources as the storage URL signer),
  and must be at least 32 bytes. With no secret nothing is signed: `sign/2` answers
  `{:error, :no_secret}` and the flow refuses to issue a code (never a predictable one).
  """

  alias PhoenixKit.Config

  @prefix "ct_"
  @purpose "phoenix_kit_api_confirm_v1"
  @mac_bytes 24

  @doc "Signs a row uuid. `secret` defaults to the application's."
  @spec sign(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, :no_secret}
  def sign(uuid, secret \\ secret())

  def sign(uuid, secret) when is_binary(uuid) and is_binary(secret),
    do: {:ok, @prefix <> uuid <> "_" <> mac(uuid, secret)}

  def sign(_uuid, _secret), do: {:error, :no_secret}

  @doc "Checks a code and returns the row uuid it names. Never raises."
  @spec verify(term(), String.t() | nil) :: {:ok, String.t()} | :error
  def verify(token, secret \\ secret())

  def verify(@prefix <> rest, secret) when is_binary(secret) do
    with <<uuid::binary-size(36), "_", presented::binary>> <- rest,
         {:ok, uuid} <- Ecto.UUID.cast(uuid),
         true <- Plug.Crypto.secure_compare(mac(uuid, secret), presented) do
      {:ok, uuid}
    else
      _ -> :error
    end
  end

  def verify(_token, _secret), do: :error

  @doc "The application's secret, or `nil` when none of the sources has a usable one."
  @spec secret() :: String.t() | nil
  def secret do
    usable(Config.get(:secret_key_base, nil)) || from_parent_endpoint() ||
      usable(endpoint_secret(PhoenixKitWeb.Endpoint))
  end

  defp from_parent_endpoint do
    case Config.get_parent_endpoint() do
      {:ok, endpoint} -> usable(endpoint_secret(endpoint))
      _ -> nil
    end
  end

  defp endpoint_secret(endpoint) do
    if Code.ensure_loaded?(endpoint) and function_exported?(endpoint, :config, 1),
      do: endpoint.config(:secret_key_base)
  rescue
    _ -> nil
  end

  defp usable(secret) when is_binary(secret) and byte_size(secret) >= 32, do: secret
  defp usable(_other), do: nil

  defp mac(uuid, secret) do
    key = :crypto.mac(:hmac, :sha256, secret, @purpose)

    :hmac
    |> :crypto.mac(:sha256, key, "api-confirm:" <> uuid)
    |> binary_part(0, @mac_bytes)
    |> Base.url_encode64(padding: false)
  end
end
