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

      assert Routes.user_settings_path() == "/account"
    end

    test "the override is used verbatim — no prefix, no locale segment" do
      put_setting("user_settings_path", "/account")

      # It is the host's own path: core neither prepends its url prefix nor
      # inserts a locale, so asking for one changes nothing.
      assert Routes.user_settings_path(locale: "ru") == "/account"
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
  end
end
