defmodule PhoenixKit.Email.AuthEmailsLayoutTest do
  @moduledoc """
  Core's own auth emails reach the reader with an HTML body in the layout.

  They ship text-only copy, so without the layout they would go out as plain
  text. Each delivery path is checked: `UserNotifier`'s shared templated send,
  and the magic link, which `Mailer` sends on its own.
  """

  use PhoenixKit.DataCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKit.Mailer
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserNotifier

  defp user(locale \\ "en") do
    %User{email: "reader@example.test", custom_fields: %{"preferred_locale" => locale}}
  end

  defp assert_in_layout(email, url) do
    assert email.html_body =~ "<!DOCTYPE html>"
    assert email.html_body =~ "<title>#{email.subject}</title>"
    assert email.html_body =~ ~s(<a href="#{url}">#{url}</a>)
    refute email.text_body =~ "<"
    assert email.text_body =~ url
  end

  test "confirmation instructions (UserNotifier's templated send)" do
    url = "https://shop.example.test/users/confirm/abc"
    assert {:ok, email} = UserNotifier.deliver_confirmation_instructions(user(), url)

    assert_in_layout(email, url)
  end

  test "password reset instructions (UserNotifier's templated send), in German" do
    url = "https://shop.example.test/users/reset/abc"
    assert {:ok, email} = UserNotifier.deliver_reset_password_instructions(user("de"), url)

    assert_in_layout(email, url)
    assert email.html_body =~ ~s(<html lang="de">)
  end

  test "magic link (Mailer's own send)" do
    url = "https://shop.example.test/users/magic-link/abc"
    assert {:ok, _} = Mailer.send_magic_link_email(user(), url)

    assert_email_sent(fn email -> assert_in_layout(email, url) end)
  end

  test "a site_url that is not http(s) is printed, never linked" do
    {:ok, _} = Settings.update_setting("site_url", "javascript:alert(1)")

    assert {:ok, _} = Mailer.send_magic_link_email(user(), "https://a.test/m")

    assert_email_sent(fn email ->
      refute email.html_body =~ ~s(href="javascript)
      assert email.html_body =~ "javascript:alert(1)"
    end)
  end
end
