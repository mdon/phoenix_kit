defmodule PhoenixKit.Utils.RecipientLocaleTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.RecipientLocale

  doctest PhoenixKit.Utils.RecipientLocale

  describe "preferred/1" do
    test "returns the stored dialect verbatim" do
      assert RecipientLocale.preferred(user_with("en-GB")) == "en-GB"
    end

    test "treats an absent, empty, or non-string preference as no preference" do
      for fields <- [%{}, %{"preferred_locale" => ""}, %{"preferred_locale" => nil}] do
        assert RecipientLocale.preferred(%{custom_fields: fields}) == nil
      end
    end

    test "returns nil for a recipient that carries no custom_fields at all" do
      # The magic-link registration path delivers to a bare address: no account
      # exists yet, so there is nowhere for a preference to live.
      assert RecipientLocale.preferred("someone@example.com") == nil
      assert RecipientLocale.preferred(%{email: "someone@example.com"}) == nil
      assert RecipientLocale.preferred(%{custom_fields: nil}) == nil
    end
  end

  describe "base/1" do
    test "narrows a dialect to its base language for Gettext" do
      assert RecipientLocale.base(user_with("pt-BR")) == "pt"
    end

    test "leaves a bare base code alone" do
      assert RecipientLocale.base(user_with("uk")) == "uk"
    end

    test "returns nil with no preference, meaning 'leave the locale alone'" do
      assert RecipientLocale.base(%{custom_fields: %{}}) == nil
      assert RecipientLocale.base("someone@example.com") == nil
    end
  end

  describe "for_rendering/1" do
    test "prefers the recipient's own dialect over the site default" do
      assert RecipientLocale.for_rendering(user_with("uk")) == "uk"
    end

    test "keeps the dialect rather than narrowing it" do
      # Template resolution tries "en-GB" before "en", so pre-truncating here
      # would silently discard a dialect-specific translation.
      assert RecipientLocale.for_rendering(user_with("en-GB")) == "en-GB"
    end

    test "always answers with a usable locale, whatever the recipient is" do
      # The contract every caller depends on: never nil, so a template lookup
      # always has something to key on. The exact site default is Settings'
      # business and varies by install.
      for recipient <- [%{custom_fields: %{}}, "someone@example.com", %{email: "a@b.c"}, nil] do
        assert locale = RecipientLocale.for_rendering(recipient)
        assert is_binary(locale) and locale != ""
      end
    end
  end

  defp user_with(locale), do: %{custom_fields: %{"preferred_locale" => locale}}
end
