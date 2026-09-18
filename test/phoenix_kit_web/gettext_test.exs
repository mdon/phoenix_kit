defmodule PhoenixKitWeb.GettextTest do
  @moduledoc """
  The backend stores translations in a compact lookup table instead of one
  function clause per message. These tests pin the Gettext.Backend contract
  so a future simplification cannot silently change lookup, plural forms,
  interpolation, or the extract-surface metadata.
  """
  use ExUnit.Case, async: true

  @backend PhoenixKitWeb.Gettext

  setup do
    previous = Gettext.get_locale(@backend)
    on_exit(fn -> Gettext.put_locale(@backend, previous) end)
    :ok
  end

  describe "backend metadata" do
    test "known_locales includes every shipped catalogue" do
      locales = Gettext.known_locales(@backend)

      assert Enum.sort(locales) == ~w(de en es et fr it pl ru)
    end

    test "extract-surface callbacks stay populated" do
      assert @backend.__gettext__(:otp_app) == :phoenix_kit
      assert @backend.__gettext__(:priv) == "priv/gettext"
      assert @backend.__gettext__(:default_domain) == "default"
      assert @backend.__gettext__(:interpolation) == Gettext.Interpolation.Default
      assert is_binary(@backend.__gettext__(:default_locale))
    end

    test "unchanged PO files do not request a mix recompile" do
      refute @backend.__mix_recompile__?()
    end
  end

  describe "singular lookup" do
    test "English falls through empty msgstr to the msgid" do
      Gettext.put_locale(@backend, "en")
      assert Gettext.gettext(@backend, "Dashboard") == "Dashboard"
    end

    test "Russian returns the translated string" do
      Gettext.put_locale(@backend, "ru")
      assert Gettext.gettext(@backend, "Dashboard") == "Панель управления"
    end

    test "a missing msgid returns the msgid" do
      Gettext.put_locale(@backend, "ru")
      assert Gettext.gettext(@backend, "definitely-not-a-msgid") == "definitely-not-a-msgid"
    end

    test "errors domain is a separate catalogue" do
      Gettext.put_locale(@backend, "ru")
      assert Gettext.dgettext(@backend, "errors", "can't be blank") == "не может быть пустым"
    end
  end

  describe "interpolation" do
    test "substitutes bindings in a translated string" do
      Gettext.put_locale(@backend, "ru")

      assert Gettext.gettext(@backend, "Welcome to the %{project_title} administration panel",
               project_title: "Acme"
             ) == "Добро пожаловать в панель администрирования Acme"
    end

    test "missing bindings keep the placeholder and do not raise" do
      Gettext.put_locale(@backend, "en")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Gettext.gettext(
                   @backend,
                   "Welcome to the %{project_title} administration panel"
                 ) == "Welcome to the %{project_title} administration panel"
        end)

      assert log =~ "missing Gettext bindings: [:project_title]"
    end
  end

  describe "plural lookup" do
    # Russian: 1 → form 0, 2 → form 1, 5 → form 2.
    @msgid "%{count} file permanently deleted"
    @msgid_plural "%{count} files permanently deleted"

    test "picks the singular, paucal, and plural Russian forms" do
      Gettext.put_locale(@backend, "ru")

      assert Gettext.ngettext(@backend, @msgid, @msgid_plural, 1) ==
               "1 файл удалён навсегда"

      assert Gettext.ngettext(@backend, @msgid, @msgid_plural, 2) ==
               "2 файла удалено навсегда"

      assert Gettext.ngettext(@backend, @msgid, @msgid_plural, 5) ==
               "5 файлов удалено навсегда"
    end

    test "errors domain plurals interpolate count" do
      Gettext.put_locale(@backend, "ru")

      assert Gettext.dngettext(
               @backend,
               "errors",
               "should have %{count} item(s)",
               "should have %{count} item(s)",
               3
             ) == "должно быть 3 элемента"
    end

    test "a missing plural msgid interpolates the English fallback" do
      Gettext.put_locale(@backend, "ru")

      assert Gettext.ngettext(@backend, "%{count} widget", "%{count} widgets", 4) == "4 widgets"
    end
  end
end
