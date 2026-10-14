defmodule PhoenixKit.API.ConfigTest do
  @moduledoc """
  `PhoenixKit.API.Config` against the real Settings table. The API is off by
  default and every read fails closed.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.API.Config
  alias PhoenixKit.Settings

  describe "switches" do
    test "both are off when nothing is stored" do
      refute Config.admin_enabled?()
      refute Config.public_enabled?()
    end

    test "each follows its own setting" do
      {:ok, _} = Settings.update_boolean_setting("api_admin_enabled", true)
      assert Config.admin_enabled?()
      refute Config.public_enabled?()

      {:ok, _} = Settings.update_boolean_setting("api_public_enabled", true)
      assert Config.public_enabled?()

      {:ok, _} = Settings.update_boolean_setting("api_admin_enabled", false)
      refute Config.admin_enabled?()
      assert Config.public_enabled?()
    end

    test "a value that is not exactly true or false counts as off" do
      {:ok, _} = Settings.update_setting("api_admin_enabled", "yes")
      refute Config.admin_enabled?()

      {:ok, _} = Settings.update_setting("api_admin_enabled", "TRUE")
      refute Config.admin_enabled?()
    end

    test "an unreadable Settings store counts as off" do
      {:ok, _} = Settings.update_boolean_setting("api_admin_enabled", true)
      assert Config.admin_enabled?()

      # update mode makes every Settings read answer nil, as when the database
      # is not reachable.
      previous = Application.get_env(:phoenix_kit, :update_mode, false)
      Application.put_env(:phoenix_kit, :update_mode, true)
      on_exit(fn -> Application.put_env(:phoenix_kit, :update_mode, previous) end)

      refute Config.admin_enabled?()
      refute Config.public_enabled?()
    end
  end

  describe "list settings" do
    test "are empty by default" do
      assert Config.disabled_tools() == []
      assert Config.mcp_allowed_origins() == []
    end

    test "are read from newline-separated text, trimmed and de-duplicated" do
      {:ok, _} =
        Settings.update_setting(
          "api_disabled_tools",
          "ecommerce.set_prices\r\n  catalogue.delete_products \n\necommerce.set_prices\n"
        )

      assert Config.disabled_tools() == ["ecommerce.set_prices", "catalogue.delete_products"]

      {:ok, _} =
        Settings.update_setting("api_mcp_allowed_origins", "https://a.example\nhttps://b.example")

      assert Config.mcp_allowed_origins() == ["https://a.example", "https://b.example"]
    end

    test "encode_list/1 and parse_list/1 round-trip" do
      items = ["one.tool", "two.tool"]
      assert items |> Config.encode_list() |> Config.parse_list() == items
      assert Config.parse_list(nil) == []
      assert Config.parse_list("") == []
    end
  end
end
