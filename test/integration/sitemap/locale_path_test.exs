defmodule PhoenixKit.Integration.Sitemap.LocalePathTest do
  @moduledoc """
  Pins the locale-segment policy shared by the three sitemap sources
  (`publishing`, `static`, `posts`). The behaviour is centralised in
  `PhoenixKit.Modules.Sitemap.LocalePath.emit_prefix?/2`; the sources
  delegate to it so this one test file covers all three.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Sitemap.LocalePath
  alias PhoenixKit.Settings

  describe "emit_prefix?/2 — single-language sites" do
    test "returns false when Languages module is disabled" do
      Settings.update_setting("languages_enabled", "false")
      refute LocalePath.emit_prefix?("en", true)
      refute LocalePath.emit_prefix?("fr", false)
    end

    test "returns false when only one language is enabled" do
      config = %{
        "languages" => [
          %{"code" => "en", "name" => "English", "is_default" => true, "is_enabled" => true}
        ]
      }

      Settings.update_setting("languages_enabled", "true")
      Settings.update_json_setting("languages_config", config)

      refute LocalePath.emit_prefix?("en", true)
    end
  end

  describe "emit_prefix?/2 — multi-language sites" do
    setup do
      config = %{
        "languages" => [
          %{"code" => "en", "name" => "English", "is_default" => true, "is_enabled" => true},
          %{"code" => "es", "name" => "Spanish", "is_default" => false, "is_enabled" => true},
          %{"code" => "fr", "name" => "French", "is_default" => false, "is_enabled" => true}
        ]
      }

      Settings.update_setting("languages_enabled", "true")
      Settings.update_json_setting("languages_config", config)

      on_exit(fn ->
        Settings.update_setting("languages_enabled", "false")
        Settings.update_boolean_setting("default_language_no_prefix", false)
      end)

      :ok
    end

    test "nil language always returns false" do
      refute LocalePath.emit_prefix?(nil, true)
      refute LocalePath.emit_prefix?(nil, false)
    end

    test "non-primary languages always get the prefix regardless of setting" do
      assert LocalePath.emit_prefix?("es", false)
      assert LocalePath.emit_prefix?("fr", false)

      Languages.set_default_language_no_prefix(true)
      assert LocalePath.emit_prefix?("es", false)
      assert LocalePath.emit_prefix?("fr", false)
    end

    test "primary language gets the prefix when setting is OFF (the default)" do
      Languages.set_default_language_no_prefix(false)
      assert LocalePath.emit_prefix?("en", true)
    end

    test "primary language is stripped when setting is ON" do
      Languages.set_default_language_no_prefix(true)
      refute LocalePath.emit_prefix?("en", true)
    end

    test "is_default=false treats the language as non-primary even if the code matches" do
      # A misuse: caller passes the primary code with is_default=false.
      # The helper doesn't second-guess the caller — it trusts is_default.
      Languages.set_default_language_no_prefix(true)
      assert LocalePath.emit_prefix?("en", false)
    end
  end

  describe "single_language_mode?/0 defensive fallback" do
    test "returns true when languages_config is missing entirely" do
      # Fresh case-by-case state: Languages module disabled, no config.
      Settings.update_setting("languages_enabled", "false")
      assert LocalePath.single_language_mode?()
    end
  end
end
