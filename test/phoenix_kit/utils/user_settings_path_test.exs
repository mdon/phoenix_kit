defmodule PhoenixKit.Utils.UserSettingsPathTest do
  @moduledoc """
  `Routes.user_settings_path/1` — the single resolver every "Settings" entry
  in the user menu goes through.

  Like `safe_destination_settings_test.exs`, this file starts the settings
  cache and primes it rather than touching a database:
  `get_setting_cached/2` consults the cache BEFORE the update-mode
  short-circuit `test_helper.exs` turns on when no database is reachable, so a
  primed key reads exactly as it would from a live row.

  `async: false` and a per-test cache: the cache is a globally named process,
  and a primed `user_settings_path` visible to a concurrent test would change
  that test's answer.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Utils.Routes

  setup do
    # Mirrors safe_destination_settings_test.exs: with a database reachable a
    # cache miss becomes a real query from a process owning no sandbox
    # connection (an OwnershipError, not a miss), so check out either way.
    if Application.get_env(:phoenix_kit, :test_repo_available, false) do
      :ok = Sandbox.checkout(PhoenixKit.Test.Repo)
    end

    start_supervised!({PhoenixKit.Cache.Registry, []})
    start_supervised!({PhoenixKit.Cache, name: :settings})
    :ok
  end

  defp put_setting(key, value), do: PhoenixKit.Cache.put(:settings, key, value)

  describe "with no override configured" do
    test "resolves to core's own account page" do
      assert Routes.user_settings_path() == Routes.path("/profile/settings")
    end

    test "threads the locale through, like path/2" do
      assert Routes.user_settings_path(locale: "en") ==
               Routes.path("/profile/settings", locale: "en")

      assert Routes.user_settings_path(locale: "ru") ==
               Routes.path("/profile/settings", locale: "ru")
    end

    test "an empty setting counts as unset, not as a path" do
      put_setting("user_settings_path", "")

      assert Routes.user_settings_path() == Routes.path("/profile/settings")
    end

    test "whitespace-only counts as unset too" do
      put_setting("user_settings_path", "   ")

      assert Routes.user_settings_path() == Routes.path("/profile/settings")
    end
  end

  describe "with an override configured" do
    test "the host's path wins" do
      put_setting("user_settings_path", "/account")

      assert Routes.user_settings_path(locale: "ru") == "/ru/account"
    end

    test "the override gets the same locale segment path/2 would insert for the default page" do
      put_setting("user_settings_path", "/account")

      assert Routes.user_settings_path(locale: "et") == "/et/account"
    end
  end

  describe "locale-aware host overrides (issue #843)" do
    # `setting_candidate/1` reads through `PhoenixKit.Settings.get_setting_cached/2`,
    # which is a no-op nil with no reachable DB (`:update_mode`, set by
    # `test_helper.exs`) — same defensive setup as
    # `PhoenixKit.Utils.SafeDestinationSettingsTest`, so this exercises the real
    # cache-backed read either way.
    test "url_prefix is never added to a host page reached at its own root" do
      # "/account" is the HOST's own page — it is not mounted under core's
      # url_prefix, so inserting one here would nest a host page under core's
      # mount point, e.g. `/phoenix_kit/ru/account`, a path the host never
      # declared.
      put_setting("user_settings_path", "/account")

      refute Routes.user_settings_path(locale: "ru") =~ Routes.url_prefix()
    end

    test "an override pointed back at one of core's own pages localizes exactly like the default" do
      put_setting("user_settings_path", "/phoenix_kit/profile/settings")

      assert Routes.user_settings_path(locale: "ru") ==
               Routes.path("/profile/settings", locale: "ru")
    end

    test "an override that already carries a locale segment is left untouched" do
      put_setting("user_settings_path", "/en/account")

      assert Routes.user_settings_path(locale: "en") == "/en/account"

      # Even a different requested locale does not replace the existing
      # segment — this module only ever ADDS a missing locale, never swaps one.
      assert Routes.user_settings_path(locale: "ru") == "/en/account"
    end

    test "the default locale on a prefixless-primary site leaves the override untouched" do
      put_setting("user_settings_path", "/account")
      put_setting("default_language_no_prefix", "true")

      assert Routes.user_settings_path(locale: "en") == "/account"
    end

    test "an absolute external URL override is still rejected — falls back to the default, unchanged" do
      put_setting("user_settings_path", "https://evil.example/settings")

      assert Routes.user_settings_path(locale: "ru") ==
               Routes.path("/profile/settings", locale: "ru")
    end
  end

  describe "override guarding" do
    # The setting is validated on save, but re-guarded on read so a
    # hand-edited row cannot turn a menu entry into an off-site link.
    test "a protocol-relative URL is refused and falls back" do
      put_setting("user_settings_path", "//evil.example.com")

      assert Routes.user_settings_path() == Routes.path("/profile/settings")
    end

    test "an absolute URL is refused and falls back" do
      put_setting("user_settings_path", "https://evil.example.com/account")

      assert Routes.user_settings_path() == Routes.path("/profile/settings")
    end

    test "a backslash-escaped root is refused and falls back" do
      put_setting("user_settings_path", "/\\evil.example.com")

      assert Routes.user_settings_path() == Routes.path("/profile/settings")
    end

    test "a control character is refused and falls back" do
      # Browsers strip tab/CR/LF, so "/\t/evil.com" would land as "//evil.com".
      put_setting("user_settings_path", "/\t/evil.example.com")

      assert Routes.user_settings_path() == Routes.path("/profile/settings")
    end

    test "a relative path (no leading slash) is refused and falls back" do
      put_setting("user_settings_path", "account")

      assert Routes.user_settings_path() == Routes.path("/profile/settings")
    end

    test "/users/log-out is refused and falls back" do
      # A local path, so `local_path?/1` alone would let it through — but
      # every "Settings" link in the app resolves through this function, and
      # a menu entry that signs the user out is exactly the bounce
      # `usable_candidate?/1` exists to catch (same guard as
      # `main_page_path/0` and `after_login_path`).
      put_setting("user_settings_path", "/users/log-out")

      assert Routes.user_settings_path() == Routes.path("/profile/settings")
    end
  end
end
