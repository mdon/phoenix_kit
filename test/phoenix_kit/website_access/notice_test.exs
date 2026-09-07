defmodule PhoenixKit.WebsiteAccess.NoticeTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.WebsiteAccess.Notice

  setup do
    Settings.update_boolean_setting(Notice.enabled_key(), true)
    Settings.update_setting(Notice.text_key(), "This is the dev site")
    Settings.update_setting(Notice.link_key(), "https://www.example.com")
    Settings.update_setting(Notice.icon_key(), "warning")
    :ok
  end

  test "needs the switch and a text" do
    assert Notice.enabled?()
    Settings.update_setting(Notice.text_key(), "   ")
    refute Notice.enabled?()
    assert Notice.switched_on?()
    assert Notice.html() == nil
  end

  test "the banner is escaped and marked" do
    Settings.update_setting(Notice.text_key(), "<script>alert(1)</script> & co")
    html = Notice.html()
    assert html =~ "data-phoenix-kit-notice"
    assert html =~ ~s(role="status")
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
    assert html =~ "&amp; co"
    assert html =~ "⚠️"
    assert html =~ ~s(href="https://www.example.com")
  end

  test "only http(s) URLs or site paths make a link" do
    for bad <- ["javascript:alert(1)", "ftp://x", "www.example.com"] do
      Settings.update_setting(Notice.link_key(), bad)
      assert Notice.link() == nil, bad
      refute Notice.html() =~ "<a "
    end

    Settings.update_setting(Notice.link_key(), "/somewhere")
    assert Notice.link() == "/somewhere"
  end

  test "unknown icons fall back" do
    Settings.update_setting(Notice.icon_key(), "dragon")
    assert Notice.icon() in Notice.icons()
  end
end
