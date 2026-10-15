defmodule PhoenixKit.API.Keys.Token do
  @moduledoc """
  The API key token format: `pk_<prefix>_<secret>`.

  - `prefix` is 8 lowercase hex characters (4 random bytes). It is stored in the
    clear, is unique, and is how a key row is found.
  - `secret` is 32 random bytes written as 43 base64url characters (no padding).
    It may contain `_`, so a token is split on its first two underscores only.
  - Only `SHA-256(secret bytes)` is stored (`secret_hash`). The token itself is
    shown once, when the key is created.

  The secret has 256 bits of entropy, so a fast hash is enough: there is nothing
  to brute-force, unlike a human password.
  """

  @prefix_bytes 4
  @secret_bytes 32
  @max_token_length 128
  @token_pattern ~r/\Apk_([0-9a-f]{8})_([A-Za-z0-9_-]{43})\z/
  @prefix_pattern ~r/\Apk_([0-9a-f]{8})_/

  @doc """
  Generates a new token.

  Returns `{prefix, token, secret_hash}`. Store `prefix` and `secret_hash`; show
  `token` to the person once and forget it.
  """
  @spec generate() :: {prefix :: String.t(), token :: String.t(), secret_hash :: binary()}
  def generate do
    prefix = @prefix_bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    secret = :crypto.strong_rand_bytes(@secret_bytes)
    token = "pk_" <> prefix <> "_" <> Base.url_encode64(secret, padding: false)
    {prefix, token, hash(secret)}
  end

  @doc """
  Splits a presented token into its prefix and the hash of its secret.

  Returns `:error` for anything that is not a canonical token: wrong length,
  another scheme, upper-case prefix, a secret that is not exactly 32 bytes.
  """
  @spec parse(term()) :: {:ok, prefix :: String.t(), secret_hash :: binary()} | :error
  def parse(token) when is_binary(token) and byte_size(token) <= @max_token_length do
    with [_, prefix, secret_text] <- Regex.run(@token_pattern, token),
         {:ok, secret} <- Base.url_decode64(secret_text, padding: false),
         @secret_bytes <- byte_size(secret),
         true <- Base.url_encode64(secret, padding: false) == secret_text do
      {:ok, prefix, hash(secret)}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  @doc """
  The prefix of a token, or `nil` when the text does not start like one.

  Looks only at `pk_<8 hex>_`; it does not validate the secret. Safe for logging,
  because the prefix is not secret.
  """
  @spec prefix(term()) :: String.t() | nil
  def prefix(token) when is_binary(token) do
    case Regex.run(@prefix_pattern, token) do
      [_, prefix] -> prefix
      _ -> nil
    end
  end

  def prefix(_), do: nil

  @doc "SHA-256 of the raw secret bytes."
  @spec hash(binary()) :: binary()
  def hash(secret) when is_binary(secret), do: :crypto.hash(:sha256, secret)

  @doc "Constant-time comparison of two hashes."
  @spec matches?(binary(), binary()) :: boolean()
  def matches?(presented_hash, stored_hash)
      when is_binary(presented_hash) and is_binary(stored_hash) do
    Plug.Crypto.secure_compare(presented_hash, stored_hash)
  end
end
