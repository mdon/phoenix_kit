defmodule PhoenixKitWeb.Live.ModulesNamesTranslationTest do
  @moduledoc """
  The Modules page translates each module's `module_name/0` through core's
  catalogs (`PhoenixKitWeb.Live.Modules._register_module_translations/0`),
  so a module that renames itself needs its new name here too, or the page
  shows it in English in every other locale. The catalogue module took its
  pages' name, "Catalogues", on 2026-09-19.

  DB-free.
  """
  use ExUnit.Case, async: true

  defp in_locale(locale, msgid) do
    Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fn ->
      Gettext.gettext(PhoenixKitWeb.Gettext, msgid)
    end)
  end

  test "the catalogue module's name is translated under both its names" do
    for {locale, old, new} <- [
          {"et", "Kataloog", "Kataloogid"},
          {"ru", "Каталог", "Каталоги"},
          {"de", "Katalog", "Kataloge"}
        ] do
      assert in_locale(locale, "Catalogue") == old, locale
      assert in_locale(locale, "Catalogues") == new, locale
    end
  end
end
