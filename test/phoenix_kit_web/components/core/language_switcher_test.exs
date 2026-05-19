defmodule PhoenixKitWeb.Components.Core.LanguageSwitcherTest do
  @moduledoc """
  Tests the `:per_translation_urls` attr on `Components.Core.LanguageSwitcher`.

  When a feature module (e.g. `phoenix_kit_publishing`) computes per-translation
  URLs that the simple locale-rewrite default can't reproduce, the consumer
  passes them through this attr and the switcher uses those explicit URLs
  instead of `generate_base_code_url/2`. Falls back to the default when no
  entry matches the requested base code.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]

  alias PhoenixKitWeb.Components.Core.LanguageSwitcher

  defp two_languages do
    [
      %{code: "en-US", name: "English (US)", is_primary: true},
      %{code: "fr", name: "French", is_primary: false}
    ]
  end

  describe "per_translation_urls — atom-keyed list (publishing's shape)" do
    test "uses the publishing URL when the language's base code matches" do
      assigns = %{
        per_urls: [
          %{code: "en", url: "/blog/my-post"},
          %{code: "fr", url: "/fr/blog/mon-article"}
        ],
        languages: two_languages()
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/some/page"
          per_translation_urls={@per_urls}
        />
        """)

      # Both entries should link to publishing's explicit URLs, NOT the locale-rewrite
      # default (which would prepend the configured url_prefix and locale segment).
      assert html =~ ~s(href="/blog/my-post")
      assert html =~ ~s(href="/fr/blog/mon-article")
    end

    test "falls back to locale-rewrite default when base code not in the list" do
      # The locale-rewrite default uses `Routes.path/2` which prepends the
      # configured `url_prefix` (set to `/phoenix_kit` in test config).
      assigns = %{
        per_urls: [%{code: "en", url: "/blog/my-post"}],
        languages: two_languages()
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/some/page"
          per_translation_urls={@per_urls}
        />
        """)

      # English uses the override (no url_prefix prepended).
      assert html =~ ~s(href="/blog/my-post")
      # French has no override → locale-rewrite default with url_prefix.
      assert html =~ ~s(href="/phoenix_kit/fr/some/page")
    end

    test "normalizes full dialect codes to base codes for lookup" do
      # The list entry uses full code 'en-US' but the switcher iterates languages
      # by base code 'en' — DialectMapper.extract_base/1 normalizes both sides.
      assigns = %{
        per_urls: [%{code: "en-US", url: "/blog/normalized"}],
        languages: two_languages()
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en-US"
          languages={@languages}
          current_path="/some/page"
          per_translation_urls={@per_urls}
        />
        """)

      assert html =~ ~s(href="/blog/normalized")
    end
  end

  describe "per_translation_urls — string-keyed list" do
    test "accepts both atom and string keys for the entry's `code` field" do
      assigns = %{
        per_urls: [%{"code" => "fr", "url" => "/fr/string-keyed"}],
        languages: two_languages()
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/some/page"
          per_translation_urls={@per_urls}
        />
        """)

      assert html =~ ~s(href="/fr/string-keyed")
    end
  end

  describe "per_translation_urls — pass-through cases" do
    test "nil falls back to default URL for every language (no override applied)" do
      assigns = %{languages: two_languages()}

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/some/page"
          per_translation_urls={nil}
        />
        """)

      # Both languages use the locale-rewrite default with url_prefix.
      # `default_language_no_prefix` is OFF (the default) and no DB is
      # reachable for this unit test, so the primary locale ALSO gets a
      # prefix. The "ON" branch (prefixless primary) is covered DB-side
      # in `test/integration/languages/default_language_no_prefix_test.exs`.
      assert html =~ ~s(href="/phoenix_kit/en/some/page")
      assert html =~ ~s(href="/phoenix_kit/fr/some/page")
    end

    test "empty list falls back to default URL for every language" do
      assigns = %{languages: two_languages()}

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/some/page"
          per_translation_urls={[]}
        />
        """)

      # Setting OFF (default) + no DB → primary locale also gets prefix.
      assert html =~ ~s(href="/phoenix_kit/en/some/page")
      assert html =~ ~s(href="/phoenix_kit/fr/some/page")
    end

    test "missing attr (default nil) preserves the historical default behavior" do
      # No per_translation_urls passed at all — same as the pre-feature
      # caller pattern. Pinning test that the default attr value of nil
      # doesn't accidentally short-circuit `resolve_url/3`.
      assigns = %{languages: two_languages()}

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/some/page"
        />
        """)

      assert html =~ ~s(href="/phoenix_kit/fr/some/page")
    end
  end
end
