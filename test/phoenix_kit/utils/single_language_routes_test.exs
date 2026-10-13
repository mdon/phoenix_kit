defmodule PhoenixKit.Utils.SingleLanguageRoutesTest do
  @moduledoc """
  URL emission and the primary language while multi-language support is off.

  A single-language site has no other language to switch to, so a locale
  segment carries no meaning: no URL gets one, whatever locale it is built for.
  Its primary language is the default language stored in `languages_config`
  (the switch keeps that configuration while off), then the runtime
  `config :phoenix_kit, default_locale`, never a hardcoded `"en"`.

  Uses a primed settings cache instead of a database.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.LanguageSettings
  alias PhoenixKit.Utils.Routes

  describe "single-language mode emits no locale segment" do
    setup do
      LanguageSettings.single_language!()
    end

    test "for the primary language" do
      assert Routes.path("/cart", locale: "en") == "/phoenix_kit/cart"
    end

    test "for any other language" do
      assert Routes.path("/cart", locale: "de") == "/phoenix_kit/cart"
      assert Routes.path("/", locale: "uk") == "/phoenix_kit/"
    end

    test "for the locale taken from the process" do
      Gettext.put_locale(PhoenixKitWeb.Gettext, "de")
      assert Routes.path("/users/log-in") == "/phoenix_kit/users/log-in"
    after
      Gettext.put_locale(PhoenixKitWeb.Gettext, "en")
    end

    test "for admin paths" do
      assert Routes.path("/admin/users", locale: "et") == "/phoenix_kit/admin/users"
      assert Routes.admin_path("/admin/users", "en") == "/phoenix_kit/admin/users"
      assert Routes.admin_path("/admin/users", "et") == "/phoenix_kit/admin/users"
    end

    test "for a served path override" do
      assert Routes.localize_served_path("/crm/settings", locale: "et") == "/crm/settings"
    end

    test "for locale_aware_path/2" do
      assert Routes.locale_aware_path(%{current_locale_base: "et"}, "/shop") ==
               "/phoenix_kit/shop"
    end
  end

  describe "the primary language while the switch is off" do
    test "is the stored default language" do
      LanguageSettings.single_language!(languages: ~w(uk et))

      assert Languages.primary_language_code() == "uk"
      assert Routes.get_default_admin_locale() == "uk"
      assert Settings.get_content_language() == "uk"
      assert Languages.enabled_locale_codes() == ["uk"]
    end

    test "falls back to the runtime default_locale config" do
      LanguageSettings.single_language!()
      previous = Application.get_env(:phoenix_kit, :default_locale)
      Application.put_env(:phoenix_kit, :default_locale, "et-EE")

      try do
        assert Languages.primary_language_code() == "et-EE"
        assert Routes.get_default_admin_locale() == "et"
        assert Settings.get_content_language() == "et"
        assert Languages.enabled_locale_codes() == ["et-EE"]
      after
        if previous,
          do: Application.put_env(:phoenix_kit, :default_locale, previous),
          else: Application.delete_env(:phoenix_kit, :default_locale)
      end
    end

    test "a site with nothing configured keeps its content language: the base of default_locale" do
      LanguageSettings.single_language!()

      # Content keyed by "en" (publishing, email keys) keeps resolving; the
      # primary language itself stays the dialect.
      assert Settings.get_content_language() == "en"
      assert Settings.get_content_language_details().code == "en"
      assert Languages.primary_language_code() == "en-US"
      assert Languages.configured_primary_language_code() == nil
    end

    test "a configured primary language is returned as stored, dialect or not" do
      LanguageSettings.single_language!(languages: ~w(en-US))
      assert Settings.get_content_language() == "en-US"

      LanguageSettings.put_languages(~w(uk))
      assert Settings.get_content_language() == "uk"
      assert Settings.get_content_language_details().code == "uk"
    end

    test "get_default_language/0 keeps its nil-while-off contract" do
      LanguageSettings.single_language!(languages: ~w(uk))
      assert Languages.get_default_language() == nil
    end
  end

  describe "multilingual sites are unchanged" do
    test "the primary keeps its prefix while the no-prefix setting is off" do
      LanguageSettings.multilingual!(languages: ~w(en et))

      assert Routes.path("/cart", locale: "en") == "/phoenix_kit/en/cart"
      assert Routes.path("/cart", locale: "et") == "/phoenix_kit/et/cart"
      assert Routes.admin_path("/admin/users", "en") == "/phoenix_kit/en/admin/users"
    end

    test "only the primary drops it while the setting is on" do
      LanguageSettings.multilingual!(languages: ~w(uk en), no_prefix: true)

      assert Routes.path("/cart", locale: "uk") == "/phoenix_kit/cart"
      assert Routes.path("/cart", locale: "en") == "/phoenix_kit/en/cart"
      assert Languages.primary_language_code() == "uk"
    end
  end
end
