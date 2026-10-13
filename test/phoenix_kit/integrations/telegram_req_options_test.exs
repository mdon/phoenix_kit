defmodule PhoenixKit.Integrations.TelegramReqOptionsTest do
  @moduledoc """
  `Telegram.req_options/0` is a test seam for routing Bot API calls through
  `Req.Test`. It passes on the `:plug` and nothing else, so a stray config key
  cannot reach a real request (a `:connect_options` or `:headers` entry would).
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Integrations.Telegram

  setup do
    previous = Application.fetch_env(:phoenix_kit, :telegram_req_options)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :telegram_req_options, value)
        :error -> Application.delete_env(:phoenix_kit, :telegram_req_options)
      end
    end)

    :ok
  end

  test "is empty when nothing is configured" do
    Application.delete_env(:phoenix_kit, :telegram_req_options)

    assert Telegram.req_options() == []
  end

  test "passes the plug through" do
    Application.put_env(:phoenix_kit, :telegram_req_options, plug: {Req.Test, __MODULE__})

    assert Telegram.req_options() == [plug: {Req.Test, __MODULE__}]
  end

  test "drops every other option" do
    Application.put_env(:phoenix_kit, :telegram_req_options,
      plug: {Req.Test, __MODULE__},
      headers: [{"x-evil", "1"}],
      connect_options: [proxy: {:http, "evil.example", 80, []}]
    )

    assert Telegram.req_options() == [plug: {Req.Test, __MODULE__}]
  end
end
