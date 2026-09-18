defmodule PhoenixKit.Email.ContentDbTemplateTest do
  @moduledoc """
  `Content.resolve/5` when an email template exists in the database.

  Separate module, `async: false`: it swaps the global `:email_provider` for a
  stub, which is the only way to reach this branch — and the reason the branch
  was untested. Every auth email with an active template took it, so a shape
  mismatch here reached users while the whole suite stayed green.
  """

  use ExUnit.Case, async: false

  alias PhoenixKit.Email.Content

  @template %{name: "register", id: 7}

  defmodule StubProvider do
    @moduledoc false

    # The shape every real provider returns — core's own `DefaultProvider`
    # answers `%{subject: "", html_body: "", text_body: ""}`, and
    # `phoenix_kit_emails` validates exactly those three keys on its render.
    def get_active_template_by_name("register"), do: %{name: "register", id: 7}
    def get_active_template_by_name(_name), do: nil

    def render_template(_template, _variables, _locale) do
      %{
        subject: "Confirm your account",
        html_body: "<p>Confirm at http://example.test/c/abc</p>",
        text_body: "Confirm at http://example.test/c/abc"
      }
    end
  end

  setup do
    previous = Application.get_env(:phoenix_kit, :email_provider)
    Application.put_env(:phoenix_kit, :email_provider, StubProvider)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :email_provider, previous),
        else: Application.delete_env(:phoenix_kit, :email_provider)
    end)

    :ok
  end

  defp defaults, do: fn -> %{subject: "fallback", text: "fallback text"} end

  defp user, do: %{email: "a@b.c", custom_fields: %{}}

  describe "resolve/4 with an active database template" do
    test "carries the template's text body through as :text" do
      # `UserNotifier.deliver_templated/5` reads `content.text`. Reading the
      # provider's `:text` instead of its `:text_body` raised a KeyError on
      # every send that reached this branch — registration, password reset and
      # email change among them.
      assert Content.resolve("register", user(), %{}, defaults()).text ==
               "Confirm at http://example.test/c/abc"
    end

    test "carries the template's html body through as :html" do
      assert Content.resolve("register", user(), %{}, defaults()).html ==
               "<p>Confirm at http://example.test/c/abc</p>"
    end

    test "carries the template's subject, not the fallback copy" do
      assert Content.resolve("register", user(), %{}, defaults()).subject ==
               "Confirm your account"
    end

    test "reports the template it used, so usage tracking has something to count" do
      assert Content.resolve("register", user(), %{}, defaults()).db_template == @template
    end

    test "falls back to the translated defaults when no template matches the name" do
      resolved = Content.resolve("reset_password", user(), %{}, defaults())

      assert resolved.db_template == nil
      assert is_binary(resolved.text)
    end
  end
end
