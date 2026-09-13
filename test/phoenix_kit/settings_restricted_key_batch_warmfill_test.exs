defmodule PhoenixKit.SettingsRestrictedKeyBatchWarmfillTest do
  @moduledoc """
  The batch read-through path, `fill_missing_settings/1` (what
  `get_settings_cached/2` calls on a cache miss), and the boot warmer,
  `warm_cache_data/0`, both used to be able to cache a restricted key's
  (`@restricted_setting_keys`) decrypt failure — one as a bare `nil`, the
  other (after an earlier pass at this fix) as `@not_found_sentinel`.

  Neither is correct. `ee48b351` ("Do not cache a restricted setting the
  boot warmer cannot decrypt") already settled the rule for this exact
  situation: a decrypt failure is answered but must NOT be cached at all —
  the key may simply not be available yet (a legacy-tier host whose
  endpoint isn't up, a key rotation in flight), and the next read has to
  retry the decrypt. Caching `@not_found_sentinel` breaks that rule in a
  way that is worse than the original bare-`nil` bug: `get_setting_cached/2`
  treats that sentinel as "this row does not exist" and returns the
  caller's default WITHOUT ever retrying the decrypt, for as long as the
  entry stays cached (a full TTL, or forever without one) — and since the
  single-key and batch paths share one cache entry per key, a batch miss
  during a transient decrypt failure poisons the single-key reader too,
  for a real, currently-configured secret.

  `fill_missing_settings/1` and `warm_cache_data/0` now leave such a key
  out of the cache write entirely instead, so every read while the failure
  persists gets the caller's own defaults (or the direct decrypt attempt's
  own `nil`), and the very next read — once the key becomes decryptable
  again — gets the real value back.

  Reproduced against a REAL `PhoenixKit.Cache` GenServer (not the `:noproc`
  fallback `PhoenixKit.DataCase` would otherwise take) by making a
  genuinely-stored secret temporarily undecryptable (swapping the
  encryption key out from under it, rather than corrupting its ciphertext)
  and then restoring it — the corruption technique
  `settings_test.exs`'s "the read path never returns raw ciphertext when
  decryption fails" uses is for a *permanent* failure and can't be
  recovered from within a test.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Settings

  @cache :settings
  @key "oauth_google_client_secret"
  @working_secret "restricted-batch-warmfill-test-secret"
  @wrong_secret "restricted-batch-warmfill-test-WRONG-secret"

  setup do
    # The key resolver reads the flat `config :phoenix_kit, :secret_key_base`
    # or the PARENT app's endpoint — this repository has no parent, so its
    # own endpoint config in `config/test.exs` never reaches the resolver.
    # Every encryption test in `settings_test.exs` sets the flat key in its
    # own setup for the same reason; without it, `update_setting/2` silently
    # stores plaintext instead of `enc:v1:`-prefixed ciphertext.
    original_flat = Application.get_env(:phoenix_kit, :secret_key_base)

    on_exit(fn ->
      case original_flat do
        nil -> Application.delete_env(:phoenix_kit, :secret_key_base)
        value -> Application.put_env(:phoenix_kit, :secret_key_base, value)
      end
    end)

    Application.put_env(:phoenix_kit, :secret_key_base, @working_secret)

    start_supervised!({PhoenixKit.Cache.Registry, []})
    start_supervised!({PhoenixKit.Cache, name: @cache})
    :ok
  end

  test "a decrypt failure on the batch path is never cached, so a later successful decrypt is not blocked" do
    {:ok, _} = Settings.update_setting(@key, "real-secret")

    # Break decryption without touching the stored ciphertext: swap the key
    # the resolver reads out from under the same row.
    Application.put_env(:phoenix_kit, :secret_key_base, @wrong_secret)
    PhoenixKit.Cache.invalidate(@cache, @key)

    # A failing decrypt is answered directly — `nil`, the same as a direct,
    # non-cached read would give — but that must be the end of it.
    assert Settings.get_settings_cached([@key], %{@key => "fallback"})[@key] == nil

    # Restore the correct key. If the failure had been cached as
    # `@not_found_sentinel` (or a bare `nil`), BOTH readers below would keep
    # reading the fallback/nil instead of the real secret, because they
    # share one cache entry for this key.
    Application.put_env(:phoenix_kit, :secret_key_base, @working_secret)

    assert Settings.get_settings_cached([@key], %{@key => "fallback"})[@key] == "real-secret"
    assert Settings.get_setting_cached(@key, "fallback") == "real-secret"
  end

  test "the boot warmer excludes an undecryptable key, and the batch fill after warming does not block a later successful decrypt" do
    {:ok, _} = Settings.update_setting(@key, "warm-secret")

    Application.put_env(:phoenix_kit, :secret_key_base, @wrong_secret)

    warmed = Settings.warm_cache_data()
    refute Map.has_key?(warmed, @key)
    :ok = PhoenixKit.Cache.put_multiple(@cache, warmed)

    # First read after "boot": a genuine miss (the warmer left it out).
    # `fill_missing_settings/1` answers it directly with the failed
    # decrypt's own `nil` — that part is not what this test is about.
    assert Settings.get_settings_cached([@key], %{@key => "fallback"})[@key] == nil

    # The key becomes available again. Nothing from the failed attempt
    # should have been cached, on either path.
    Application.put_env(:phoenix_kit, :secret_key_base, @working_secret)

    assert Settings.get_settings_cached([@key], %{@key => "fallback"})[@key] == "warm-secret"
    assert Settings.get_setting_cached(@key, "fallback") == "warm-secret"
  end
end
