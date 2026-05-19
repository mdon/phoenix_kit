defmodule PhoenixKit.Utils.RoutesTest do
  use ExUnit.Case

  alias PhoenixKit.Utils.Routes

  # All assertions below assume the default language resolves to "en".
  # `Routes.get_default_language_base/0` rescues any DB lookup failure and
  # falls back to "en", so these tests run without a connected database.
  # If the test repo is ever wired up, the default still resolves to "en"
  # unless a different language is explicitly configured as default.

  describe "admin_path/2 — primary-language prefix stripping" do
    test "primary locale (en) emits no prefix" do
      assert Routes.admin_path("/admin/users", "en") == "/phoenix_kit/admin/users"
    end

    test "non-primary locale keeps its prefix" do
      assert Routes.admin_path("/admin/users", "de") == "/phoenix_kit/de/admin/users"
      assert Routes.admin_path("/admin/users", "fr") == "/phoenix_kit/fr/admin/users"
    end

    test "nil locale falls back to no prefix (no locale segment)" do
      # When no locale is supplied, admin_path delegates to `path/1`. With a
      # primary-locale fallback that's "en", the result is unprefixed.
      assert Routes.admin_path("/admin/users", nil) == "/phoenix_kit/admin/users"
    end

    test "nested admin paths follow the same rule" do
      assert Routes.admin_path("/admin/users/edit/123", "en") ==
               "/phoenix_kit/admin/users/edit/123"

      assert Routes.admin_path("/admin/users/edit/123", "de") ==
               "/phoenix_kit/de/admin/users/edit/123"
    end
  end

  describe "path/2 — non-admin routes (regression coverage)" do
    test "primary locale emits no prefix (unchanged behaviour)" do
      assert Routes.path("/users/log-in", locale: "en") == "/phoenix_kit/users/log-in"
    end

    test "non-primary locale keeps its prefix" do
      assert Routes.path("/users/log-in", locale: "de") == "/phoenix_kit/de/users/log-in"
    end

    test ":none locale opt skips the prefix entirely" do
      assert Routes.path("/users/log-in", locale: :none) == "/phoenix_kit/users/log-in"
    end
  end

  describe "admin_path/2 — backcompat for legacy /en/admin URLs" do
    # The prefixed shape is no longer EMITTED for the primary language,
    # but it must still RESOLVE (the dual-scope admin route emission
    # declares both `/:locale/admin/*` and `/admin/*`). Anyone with a
    # bookmark or external link pointing at `/phoenix_kit/en/admin/...`
    # should still reach the page. This test pins the helper-side half
    # of that contract: explicitly passing the primary locale produces
    # the prefixless shape (intended), while a non-primary locale still
    # produces the prefixed shape (which legacy `/en/admin/...` URLs
    # also match against in the route table).
    test "explicit primary locale → prefixless (intended emission)" do
      assert Routes.admin_path("/admin/users", "en") == "/phoenix_kit/admin/users"
    end

    test "explicit non-primary locale → prefixed (also the shape a legacy /en/ URL takes)" do
      assert Routes.admin_path("/admin/users", "de") == "/phoenix_kit/de/admin/users"
    end

    test "dialect-shaped locale code keeps its prefix verbatim" do
      # Full dialect codes (e.g. en-US) shouldn't ever reach the helper —
      # callers normalise to base via DialectMapper first — but if they
      # do, the helper passes them through unchanged. Pinning this so a
      # future "smart-strip" refactor doesn't accidentally treat
      # "en-US" the same as "en" and drop the prefix.
      assert Routes.admin_path("/admin/users", "en-US") == "/phoenix_kit/en-US/admin/users"
    end
  end
end
