defmodule PhoenixKit.Integrations.Telegram.SiteBot do
  @moduledoc """
  The website's Telegram bot for user notifications: one website-wide Telegram
  connection (Settings → Integrations), chosen by the admin, that delivers to
  every user who linked their chat to it (`Telegram.Linking`).

  The choice is the `telegram_notifications_connection` setting — the uuid of a
  `:system` Telegram connection. Empty means off, which is the default: a site
  that never opts in keeps today's behaviour (personal bots only).

  `connection_uuid/0` returns the uuid only while it still names an existing
  website Telegram connection, so deleting or replacing the connection turns the
  feature off instead of leaving a dangling reference.
  """

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Telegram, as: Client
  alias PhoenixKit.Settings

  @setting "telegram_notifications_connection"

  @doc "The site bot's connection uuid, or `nil` when off or no longer valid."
  @spec connection_uuid() :: String.t() | nil
  def connection_uuid do
    with uuid when is_binary(uuid) and uuid != "" <- Settings.get_setting_cached(@setting, nil),
         {:ok, %{provider: "telegram"}} <- Integrations.get_integration_by_uuid(uuid, :system) do
      uuid
    else
      _ -> nil
    end
  end

  @doc "Whether `uuid` is the connection chosen for user notifications."
  @spec selected?(String.t()) :: boolean()
  def selected?(uuid) when is_binary(uuid), do: connection_uuid() == uuid

  @doc """
  Makes `uuid` — a website Telegram connection — the one that delivers user
  notifications. There is one: choosing another replaces it, because a bot's
  updates can be read by one reader only.
  """
  @spec select(String.t(), keyword()) :: :ok | {:error, term()}
  def select(uuid, opts \\ []) when is_binary(uuid) do
    case Integrations.get_integration_by_uuid(uuid, :system) do
      {:ok, %{provider: "telegram"}} ->
        save(uuid, opts)

      _ ->
        {:error, :not_a_site_telegram_connection}
    end
  end

  @doc "Stops delivering user notifications through the website bot."
  @spec clear(keyword()) :: :ok | {:error, term()}
  def clear(opts \\ []), do: save("", opts)

  defp save(value, opts) do
    case Settings.update_setting(@setting, value, Keyword.take(opts, [:actor_uuid, :source])) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  The bot's `@username` (without the `@`), or `nil` when it cannot be told. Read
  from the last connection test; asks Telegram when that never ran.
  """
  @spec bot_username(String.t()) :: String.t() | nil
  def bot_username(uuid) when is_binary(uuid) do
    case Integrations.get_integration_by_uuid(uuid, :system) do
      {:ok, %{data: data}} -> from_status(data["validation_status"]) || from_telegram(uuid)
      _ -> nil
    end
  end

  defp from_status(status) do
    case Regex.run(~r/@([A-Za-z0-9_]+)/, to_string(status)) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp from_telegram(uuid) do
    case Client.get_me(uuid, owner: :system) do
      {:ok, %{"username" => name}} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  @doc """
  Whether the website bot has a webhook. Linking reads the bot's updates with
  `getUpdates`, which Telegram refuses on a bot that has one.
  """
  @spec webhook_set?(String.t()) :: boolean()
  def webhook_set?(uuid) when is_binary(uuid) do
    match?(
      {:ok, %{"url" => url}} when is_binary(url) and url != "",
      Client.get_webhook_info(uuid, owner: :system)
    )
  end
end
