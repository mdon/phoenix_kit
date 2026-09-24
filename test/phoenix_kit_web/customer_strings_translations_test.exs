defmodule PhoenixKitWeb.CustomerStringsTranslationsTest do
  @moduledoc """
  Pins the German and French translations added for the customer-facing
  account flows (OAuth buttons, email confirmation, email change, and
  pagination) so a future `.po` edit cannot silently drop them back to the
  English fallback.
  """
  use ExUnit.Case, async: true

  @backend PhoenixKitWeb.Gettext

  setup do
    previous = Gettext.get_locale(@backend)
    on_exit(fn -> Gettext.put_locale(@backend, previous) end)
    :ok
  end

  describe "OAuth buttons (lib/phoenix_kit_web/components/oauth_buttons.ex)" do
    test "German" do
      assert Gettext.with_locale(@backend, "de", fn ->
               Gettext.gettext(@backend, "Continue with Google")
             end) == "Weiter mit Google"
    end

    test "French" do
      assert Gettext.with_locale(@backend, "fr", fn ->
               Gettext.gettext(@backend, "Continue with Google")
             end) == "Continuer avec Google"
    end
  end

  describe "confirmation_instructions.ex" do
    test "German" do
      assert Gettext.with_locale(@backend, "de", fn ->
               Gettext.gettext(@backend, "Your email is already confirmed.")
             end) == "Ihre E-Mail-Adresse ist bereits bestätigt."
    end

    test "French" do
      assert Gettext.with_locale(@backend, "fr", fn ->
               Gettext.gettext(@backend, "Your email is already confirmed.")
             end) == "Votre adresse e-mail est déjà confirmée."
    end
  end

  describe "confirm_email_change.ex" do
    test "German" do
      assert Gettext.with_locale(@backend, "de", fn ->
               Gettext.gettext(@backend, "Email changed and confirmed. Welcome!")
             end) == "E-Mail-Adresse geändert und bestätigt. Willkommen!"
    end

    test "French" do
      assert Gettext.with_locale(@backend, "fr", fn ->
               Gettext.gettext(@backend, "Email changed and confirmed. Welcome!")
             end) == "E-mail modifié et confirmé. Bienvenue !"
    end
  end

  describe "components/core/pagination.ex" do
    test "German" do
      assert Gettext.with_locale(@backend, "de", fn ->
               Gettext.gettext(@backend, "Rows per page")
             end) == "Zeilen pro Seite"
    end

    test "French" do
      assert Gettext.with_locale(@backend, "fr", fn ->
               Gettext.gettext(@backend, "Rows per page")
             end) == "Lignes par page"
    end

    # `%{noun}` is always bound to the PLURAL noun (`@noun_plural`, default
    # "results" -> "résultats"/"Ergebnisse"), so the translation must agree
    # in number with a plural — not read like "Aucun résultats".
    test "German: 'No %{noun}' agrees with the plural noun callers pass" do
      assert Gettext.with_locale(@backend, "de", fn ->
               Gettext.gettext(@backend, "No %{noun}", noun: Gettext.gettext(@backend, "results"))
             end) == "Keine Ergebnisse"
    end

    test "French: 'No %{noun}' agrees with the plural noun callers pass" do
      assert Gettext.with_locale(@backend, "fr", fn ->
               Gettext.gettext(@backend, "No %{noun}", noun: Gettext.gettext(@backend, "results"))
             end) == "Pas de résultats"
    end
  end
end
