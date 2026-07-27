defmodule PhoenixKit.Integrations.Telegram do
  @moduledoc """
  Send messages via a stored Telegram bot integration, plus the one-shot
  read primitive the notification **chat-linking** flow needs.

  Telegram puts the bot token in the URL path (`/bot<token>/<method>`) rather
  than an `Authorization` header, so it can't ride the header-based
  `PhoenixKit.Integrations.authenticated_request/4`. This module resolves the
  token via `Integrations.get_credentials/2` (owner-scoped, so a connection is
  only reachable by an owner entitled to it) and calls the Bot API directly.

  Scope is deliberately narrow: **sending**, plus a **one-shot `getUpdates`**
  used purely to discover a user's `chat_id` when they link their chat (NOT a
  streaming receiver — long-poll loops / webhooks are out of scope).

      Telegram.send_message(conn_uuid, chat_id, "Deploy finished ✅")
      Telegram.send_message(conn_uuid, chat_id, "*Alert*", parse_mode: "MarkdownV2")

  `chat_id` is the numeric id of a user/group/channel, or `"@channelusername"`.
  A user must have messaged the bot first (Telegram's anti-spam rule) — which is
  exactly what the chat-link `/start` step arranges.
  """

  require Logger

  alias PhoenixKit.Integrations

  @api_base "https://api.telegram.org"
  @timeout 15_000

  # --- Send -----------------------------------------------------------------

  @doc """
  Sends a text message via a stored Telegram connection.

  Opts: `:parse_mode` (`"MarkdownV2"` / `"HTML"`), `:silent` (no notification
  sound), `:reply_markup` (inline/keyboard map), and `:owner` for the credential
  lookup (`:system` default, or `{type, id}`). Returns `{:ok, message}` (the
  sent Message object) or `{:error, reason}`.
  """
  @spec send_message(String.t(), integer() | String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(uuid, chat_id, text, opts \\ []) when is_binary(uuid) do
    with_token(uuid, opts, &send_message_with_token(&1, chat_id, text, opts))
  end

  @doc "Like `send_message/4` but with a raw bot token instead of a connection uuid."
  @spec send_message_with_token(String.t(), integer() | String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message_with_token(token, chat_id, text, opts \\ []) when is_binary(token) do
    %{chat_id: chat_id, text: text}
    |> maybe_put(:parse_mode, opts[:parse_mode])
    |> maybe_put(:disable_notification, opts[:silent])
    |> maybe_put(:reply_markup, opts[:reply_markup])
    |> then(&request(token, "sendMessage", &1))
  end

  # --- Chat linking (one-shot reads; NOT a receive pipeline) ----------------

  @doc """
  Reads recent updates for the bot — the one-shot primitive the chat-linking
  flow uses to discover a user's `chat_id` after they `/start` the bot.

  Defaults to `offset: -1` (peek only the latest update, WITHOUT confirming it,
  so a bot that also has its own update consumer isn't disturbed). Returns
  `{:ok, [update]}` or `{:error, reason}`.
  """
  @spec get_updates(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_updates(uuid, opts \\ []) when is_binary(uuid) do
    with_token(uuid, opts, &get_updates_with_token(&1, opts))
  end

  @doc "Like `get_updates/2` but with a raw bot token."
  @spec get_updates_with_token(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_updates_with_token(token, opts \\ []) when is_binary(token) do
    %{}
    |> maybe_put(:offset, Keyword.get(opts, :offset, -1))
    |> maybe_put(:allowed_updates, opts[:allowed_updates] || ["message"])
    |> maybe_put(:timeout, opts[:timeout])
    |> then(&request(token, "getUpdates", &1))
  end

  # --- Internals ------------------------------------------------------------

  # Resolve the bot token for a stored connection (owner-scoped via `:owner`),
  # then hand it to `fun`. Shared by every uuid-taking function above.
  defp with_token(uuid, opts, fun) do
    case Integrations.get_credentials(uuid, Keyword.take(opts, [:owner])) do
      {:ok, %{"bot_token" => token}} when is_binary(token) and token != "" -> fun.(token)
      {:ok, _} -> {:error, :not_configured}
      {:error, _} = err -> err
    end
  end

  defp request(token, method, body) do
    case Req.post("#{@api_base}/bot#{token}/#{method}", json: body, receive_timeout: @timeout) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => result}}} ->
        {:ok, result}

      # Telegram returns a JSON body with a human "description" on API errors
      # (bad chat_id, bot blocked, webhook conflict, etc.) — surface it verbatim.
      {:ok, %{body: %{"description" => description}}} ->
        {:error, description}

      {:ok, %{status: status}} ->
        {:error, "Telegram error #{status}"}

      {:error, reason} ->
        Logger.warning("[Telegram] #{method} failed: #{inspect(reason)}")
        {:error, :unreachable}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
