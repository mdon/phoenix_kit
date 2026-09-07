defmodule PhoenixKit.WebsiteAccess.RedirectTest do
  use PhoenixKit.DataCase, async: false

  import Plug.Test

  alias PhoenixKit.Settings
  alias PhoenixKit.WebsiteAccess.Redirect

  setup do
    Settings.update_boolean_setting(Redirect.enabled_key(), true)
    Settings.update_setting(Redirect.url_key(), "https://www.prod.example/")
    Settings.update_setting(Redirect.scope_key(), "everyone")
    :ok
  end

  test "target_url normalises and validates" do
    assert Redirect.target_url() == "https://www.prod.example"
    assert Redirect.enabled?()

    for bad <- [
          "ftp://x",
          "   ",
          "https://",
          "https://user:pw@prod.example",
          "https://prod.example/?x=1",
          "https://prod.example/#frag",
          "https://prod.example/a b",
          "https://prod.example/\r\nX: y"
        ] do
      Settings.update_setting(Redirect.url_key(), bad)
      assert Redirect.target_url() == nil, bad
      refute Redirect.enabled?(), bad
    end

    assert Redirect.switched_on?()
  end

  test "a target with a path prefix keeps it; the destination is a URI, not glued strings" do
    Settings.update_setting(Redirect.url_key(), "https://prod.example/app/")
    assert Redirect.target_url() == "https://prod.example/app"
    assert Redirect.target_for(conn(:get, "/docs?q=1")) == "https://prod.example/app/docs?q=1"
    assert Redirect.target_for(conn(:get, "/")) == "https://prod.example/app/"
  end

  test "a public GET goes to the same path and query on production" do
    conn = conn(:get, "/about?x=1")
    assert Redirect.target_for(conn) == "https://www.prod.example/about?x=1"
    assert Redirect.target_for(conn(:get, "/")) == "https://www.prod.example/"
  end

  test "logged-in users and admin paths stay" do
    assert Redirect.target_for(conn(:get, "/about"), logged_in?: true) == nil
    assert Redirect.target_for(conn(:get, "/phoenix_kit/admin/settings")) == nil
    assert Redirect.target_for(conn(:get, "/phoenix_kit")) == nil
    assert Redirect.target_for(conn(:get, "/phoenix_kitten")) != nil, "prefix needs a boundary"
  end

  test "with the kit at the root, only the admin and account pages stay" do
    assert Redirect.kit_path?("/admin/settings", "")
    assert Redirect.kit_path?("/en/admin", "")
    assert Redirect.kit_path?("/users/log-in", "")
    assert Redirect.kit_path?("/et/users/register", "")
    refute Redirect.kit_path?("/", "")
    refute Redirect.kit_path?("/about", "")
    refute Redirect.kit_path?("/en/about", "")
    refute Redirect.kit_path?("/shop/users/profile", ""), "a locale segment has to look like one"
    assert Redirect.kit_path?("/phoenix_kit/users/log-in", "/phoenix_kit")
    refute Redirect.kit_path?("/about", "/phoenix_kit")
  end

  test "crawlers-only scope" do
    Settings.update_setting(Redirect.scope_key(), "crawlers")
    assert Redirect.target_for(conn(:get, "/about")) == nil

    bot =
      conn(:get, "/about")
      |> Plug.Conn.put_req_header("user-agent", "Mozilla/5.0 (compatible; Googlebot/2.1)")

    assert Redirect.target_for(bot) == "https://www.prod.example/about"

    assert Redirect.crawler?("bingbot/2.0")
    refute Redirect.crawler?("Mozilla/5.0 Safari")
    refute Redirect.crawler?(nil)
  end

  test "off when disabled" do
    Settings.update_boolean_setting(Redirect.enabled_key(), false)
    assert Redirect.target_for(conn(:get, "/about")) == nil
  end
end
