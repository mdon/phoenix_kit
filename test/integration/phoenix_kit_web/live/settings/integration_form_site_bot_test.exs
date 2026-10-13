defmodule PhoenixKitWeb.Live.Settings.IntegrationFormSiteBotTest do
  @moduledoc """
  The "Deliver user notifications through this bot" box on a website Telegram
  connection: it chooses the site bot, warns when the bot has a webhook (so
  linking by `getUpdates` cannot work), and the Danger Zone says so before the
  chosen bot is deleted.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Telegram.SiteBot
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @stub __MODULE__.Telegram

  setup %{conn: conn} do
    Application.put_env(:phoenix_kit, :telegram_req_options, plug: {Req.Test, @stub})
    on_exit(fn -> Application.delete_env(:phoenix_kit, :telegram_req_options) end)
    Req.Test.set_req_test_to_shared(%{})
    webhook(nil)

    {user, _token} = create_admin_user()
    admin_role = Roles.get_role_by_name("Admin")
    {:ok, _} = Permissions.grant_permission(admin_role.uuid, "integrations_system")

    {:ok, %{uuid: bot}} = Integrations.add_connection("telegram", "site bot")
    {:ok, _} = Integrations.save_setup(bot, %{"bot_token" => "111:SITE"})
    {:ok, %{uuid: other}} = Integrations.add_connection("telegram", "other bot")
    {:ok, _} = Integrations.save_setup(other, %{"bot_token" => "222:OTHER"})

    %{conn: log_in_user(conn, user), bot: bot, other: other}
  end

  # Telegram's answer to getWebhookInfo; nil = no webhook set.
  defp webhook(url) do
    Req.Test.stub(@stub, fn conn ->
      result =
        case List.last(String.split(conn.request_path, "/")) do
          "getWebhookInfo" -> %{"url" => url || ""}
          "getMe" -> %{"username" => "shop_bot"}
          _ -> true
        end

      Req.Test.json(conn, %{"ok" => true, "result" => result})
    end)
  end

  defp edit_path(uuid), do: Routes.path("/admin/settings/integrations/#{uuid}")

  defp toggle(view, value) do
    view |> form("#telegram-site-bot-form", %{"enabled" => value}) |> render_change()
  end

  describe "the delivery box" do
    test "ticking it makes this the site bot, clearing it turns delivery off", %{
      conn: conn,
      bot: bot
    } do
      {:ok, view, _html} = live(conn, edit_path(bot))
      refute SiteBot.selected?(bot)

      toggle(view, "true")
      assert SiteBot.connection_uuid() == bot

      toggle(view, "false")
      assert SiteBot.connection_uuid() == nil
    end

    test "ticking it on another bot moves the choice there", %{conn: conn, bot: bot, other: other} do
      :ok = SiteBot.select(bot)

      {:ok, view, html} = live(conn, edit_path(other))
      refute html =~ "has a webhook set"
      toggle(view, "true")

      assert SiteBot.connection_uuid() == other
    end

    test "a bot with a webhook gets a warning, one without does not", %{conn: conn, bot: bot} do
      webhook("https://shop.example/hook")
      {:ok, view, _html} = live(conn, edit_path(bot))

      assert toggle(view, "true") =~ "has a webhook set"

      webhook(nil)
      send(view.pid, :do_test_connection)
      refute render(view) =~ "has a webhook set"
    end

    test "Test connection looks for the webhook again", %{conn: conn, bot: bot} do
      {:ok, view, _html} = live(conn, edit_path(bot))
      toggle(view, "true")
      refute render(view) =~ "has a webhook set"

      webhook("https://shop.example/hook")
      send(view.pid, :do_test_connection)

      assert render(view) =~ "has a webhook set"
    end

    test "no webhook check for a bot that is not the site's", %{conn: conn, bot: bot} do
      webhook("https://shop.example/hook")
      {:ok, view, _html} = live(conn, edit_path(bot))

      send(view.pid, :do_test_connection)

      refute render(view) =~ "has a webhook set"
    end

    test "the event without a saved connection is ignored rather than crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/integrations/new"))
      render_click(view, "select_provider", %{"provider" => "telegram"})

      assert render_click(view, "set_site_bot", %{"enabled" => "true"}) =~ "Telegram"
      assert Process.alive?(view.pid)
      assert SiteBot.connection_uuid() == nil
    end
  end

  describe "Danger Zone" do
    test "names the notification bot before it is deleted", %{conn: conn, bot: bot, other: other} do
      :ok = SiteBot.select(bot)

      {:ok, _view, html} = live(conn, edit_path(bot))
      assert html =~ "everyone who linked a chat to it will stop receiving them"

      {:ok, _view, html} = live(conn, edit_path(other))
      refute html =~ "everyone who linked a chat to it will stop receiving them"
    end
  end
end
