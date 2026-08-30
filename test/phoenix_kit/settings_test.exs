defmodule PhoenixKit.SettingsTest do
  @moduledoc """
  S007: General and Users load settings into a LiveView socket that never
  renders the OAuth login secrets or the AWS key pair — only the
  Authorization page's template does. Before this, all three mounts called
  `list_all_settings/0` unconditionally, so those two pages held the real
  secret values in process state for no reason anyone could point to.

  The core's only notion of "sensitive" was `module == "integrations"`
  (`PhoenixKit.Integrations.Encryption`), and OAuth login credentials never
  belonged to that module — a black list that was silent about the one
  thing it needed to catch. `list_public_settings/0` replaces it with an
  explicit allow list (`@public_setting_keys` in settings.ex): a setting
  key that is neither on the allow list nor on `@restricted_setting_keys`
  fails the partition test below instead of silently landing wherever
  `list_public_settings/0` is called.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Settings

  describe "public/restricted setting-key partition" do
    test "every get_defaults/0 key is classified exactly once" do
      all_keys = Settings.get_defaults() |> Map.keys() |> Enum.sort()

      classified =
        (Settings.public_setting_keys() ++ Settings.restricted_setting_keys())
        |> Enum.sort()

      assert classified == all_keys, """
      The following setting keys exist in `PhoenixKit.Settings.get_defaults/0` \
      but are on neither `@public_setting_keys` nor `@restricted_setting_keys` \
      in `PhoenixKit.Settings` (or a key was removed from get_defaults/0 while \
      still listed there):

        missing from the partition: #{inspect(all_keys -- classified)}
        extra in the partition:     #{inspect(classified -- all_keys)}

      A new setting is not safe to expose by default. Classify it explicitly: \
      add it to `@public_setting_keys` if General/Users may hold its real \
      value, or to `@restricted_setting_keys` if only the page that manages \
      it should (see S007).
      """
    end

    test "public and restricted keys do not overlap" do
      public = MapSet.new(Settings.public_setting_keys())
      restricted = MapSet.new(Settings.restricted_setting_keys())

      assert MapSet.disjoint?(public, restricted),
             "a key on both lists is ambiguous: #{inspect(MapSet.intersection(public, restricted))}"
    end

    test "the OAuth secrets and AWS credentials are restricted, not public" do
      for key <- ~w(
            oauth_google_client_secret
            oauth_github_client_secret
            oauth_facebook_app_secret
            aws_access_key_id
            aws_secret_access_key
          ) do
        assert key in Settings.restricted_setting_keys(), "#{key} must be restricted"
        refute key in Settings.public_setting_keys(), "#{key} must not be public"
      end
    end

    test "the OAuth client/app identifiers stay public (they are public by OAuth's design)" do
      for key <- ~w(oauth_google_client_id oauth_github_client_id oauth_facebook_app_id) do
        assert key in Settings.public_setting_keys(), "#{key} must stay public"
      end
    end
  end

  # The tests above only prove today's lists happen to satisfy the
  # invariant — not that the invariant would actually catch a violation.
  # These re-run the same comparison the first test makes, fed a
  # deliberately corrupted list, and require it to fail. Mutating the real
  # `@public_setting_keys`/`@restricted_setting_keys` attributes isn't
  # possible from a test (they're compiled into the module), so this is the
  # closest equivalent: prove the check itself is not vacuous.
  describe "partition invariant is not vacuous" do
    test "a secret key wrongly added to the public list makes the partition fail" do
      corrupted_public = ["oauth_google_client_secret" | Settings.public_setting_keys()]
      all_keys = Settings.get_defaults() |> Map.keys() |> Enum.sort()

      classified =
        (corrupted_public ++ Settings.restricted_setting_keys())
        |> Enum.sort()

      refute classified == all_keys,
             "expected the corrupted list to fail the partition check, but it passed"
    end

    test "a new setting key missing from both lists makes the partition fail" do
      all_keys =
        Settings.get_defaults()
        |> Map.keys()
        |> Kernel.++(["a_setting_nobody_classified_yet"])
        |> Enum.sort()

      classified =
        (Settings.public_setting_keys() ++ Settings.restricted_setting_keys())
        |> Enum.sort()

      refute classified == all_keys,
             "expected the unclassified key to fail the partition check, but it passed"
    end
  end

  describe "list_public_settings/0" do
    test "returns a stored public value" do
      {:ok, _} = Settings.update_setting("project_title", "S007 Test Project")

      assert Settings.list_public_settings()["project_title"] == "S007 Test Project"
    end

    test "does not return a stored OAuth secret, even when one is set" do
      {:ok, _} = Settings.update_setting("oauth_google_client_secret", "GOCSPX-test-secret-value")

      refute Map.has_key?(Settings.list_public_settings(), "oauth_google_client_secret")
    end

    test "does not return a stored AWS secret key, even when one is set" do
      {:ok, _} = Settings.update_setting("aws_secret_access_key", "test-aws-secret-value")

      refute Map.has_key?(Settings.list_public_settings(), "aws_secret_access_key")
    end

    test "list_all_settings/0 still returns the secret (it is the unfiltered read the Authorization page needs)" do
      {:ok, _} = Settings.update_setting("oauth_google_client_secret", "GOCSPX-test-secret-value")

      assert Settings.list_all_settings()["oauth_google_client_secret"] ==
               "GOCSPX-test-secret-value"
    end
  end

  # S015 pt.1-3: oauth_*/aws_* live in this context, not
  # PhoenixKit.Integrations — `PhoenixKit.Integrations.Encryption`'s
  # single-value API (`encrypt_value/1`/`decrypt_value/1`) is reused here
  # poштучно (encrypt_fields/1 assumes an integration-shaped map, which a
  # flat setting is not). New writes only — an existing plaintext row on a
  # live install is a separate, live-database migration step, not implied
  # by this changeset (see `Setting.maybe_encrypt_restricted_value/1`).
  describe "restricted-key encryption at rest (S015)" do
    alias PhoenixKit.Integrations.Encryption
    alias PhoenixKit.Settings.Queries

    setup do
      original_flat = Application.get_env(:phoenix_kit, :secret_key_base)

      on_exit(fn ->
        case original_flat do
          nil -> Application.delete_env(:phoenix_kit, :secret_key_base)
          value -> Application.put_env(:phoenix_kit, :secret_key_base, value)
        end
      end)

      # The key resolver reads the flat `config :phoenix_kit, :secret_key_base`
      # or the PARENT app's endpoint — this repository has no parent, so its
      # own endpoint config in `config/test.exs` never reaches the resolver.
      # Every encryption test upstream sets the flat key in its own setup for
      # the same reason; this block now does too instead of assuming config.
      Application.put_env(:phoenix_kit, :secret_key_base, "s015-restricted-settings-test-secret")

      assert Encryption.enabled?(),
             "setting the flat :secret_key_base must resolve a key"

      :ok
    end

    # State 1 of 3: enc:v1:-prefixed, decrypts under the active key.
    test "decrypt_restricted_value/1: an encrypted value decrypts to the original plaintext" do
      encrypted = Encryption.encrypt_value("synthetic-oauth-secret")
      assert String.starts_with?(encrypted, "enc:v1:")

      assert Settings.decrypt_restricted_value(encrypted) ==
               {:decrypted, "synthetic-oauth-secret"}
    end

    # State 2 of 3: no prefix at all — legacy, returned as-is, but tagged
    # distinctly from state 1 (that is what "отличимо" in the card means:
    # `decrypt_restricted_value/1` itself, not `get_setting/1`, can tell
    # "already encrypted" apart from "predates encryption").
    test "decrypt_restricted_value/1: an unprefixed value is legacy, not decrypted" do
      assert Settings.decrypt_restricted_value("plain-legacy-value") ==
               {:legacy, "plain-legacy-value"}

      assert Settings.decrypt_restricted_value(nil) == {:legacy, nil}
    end

    # State 3 of 3: prefixed, but decryption itself fails (corrupted
    # ciphertext here; a rotated/mismatched key on a live install is the
    # same code path). Must be an explicit error, never a value.
    test "decrypt_restricted_value/1: a corrupted enc:v1: value is an explicit error, not a value" do
      corrupted =
        "synthetic-value-to-corrupt"
        |> Encryption.encrypt_value()
        |> String.slice(0..-6//1)

      assert {:error, _reason} = Settings.decrypt_restricted_value(corrupted)
    end

    test "write then read: a new restricted-key value is stored encrypted and reads back as plaintext" do
      {:ok, _} =
        Settings.update_setting("oauth_google_client_secret", "synthetic-round-trip-secret")

      # The write path (point 3): assert against the RAW row, not another
      # Settings.* reader — proves encryption happened at rest, not merely
      # that the read side hides it.
      raw = Queries.get_setting_by_key("oauth_google_client_secret")
      assert String.starts_with?(raw.value, "enc:v1:")
      refute raw.value == "synthetic-round-trip-secret"

      # The read path (point 2, state 1): the same plaintext comes back.
      assert Settings.get_setting("oauth_google_client_secret") == "synthetic-round-trip-secret"

      assert Settings.list_all_settings()["oauth_google_client_secret"] ==
               "synthetic-round-trip-secret"
    end

    # S015 review finding 1: warm_cache_data/0 originally read `setting.value`
    # directly, bypassing `decrypt_and_map_settings/1` — the one place every
    # OTHER multi-key read path funnels through.
    # `PhoenixKit.Cache` is a bare ETS passthrough with no notion of
    # encryption — its warmer just `:ets.insert`s whatever this function
    # returns, verbatim — so every app boot (`supervisor.ex`'s `:settings`
    # child, `sync_init: true`) filled the cache with raw `enc:v1:...` for
    # every restricted key, and `get_setting_cached/2`/`get_settings_cached/2`
    # (their own docstrings: "preferred") served it as if it were the real
    # secret on every cache HIT — no error, no log — until the next write
    # invalidated that one key.
    test "the boot-time cache warmer does not populate the cache with raw ciphertext" do
      {:ok, _} =
        Settings.update_setting("oauth_google_client_secret", "synthetic-cache-warm-secret")

      # The exact function supervisor.ex wires as the :settings cache's
      # warmer. `PhoenixKit.Cache`'s own warm_critical_data/2 is a bare
      # :ets.insert per {key, value} pair returned here — no transformation
      # of its own — so asserting on THIS return value is asserting on
      # exactly what a fresh boot would serve.
      warmed = Settings.warm_cache_data()
      assert warmed["oauth_google_client_secret"] == "synthetic-cache-warm-secret"

      # Prove it through the real cache and the public, docstring-preferred
      # get_setting_cached/2 too. Seeded directly rather than by triggering
      # the real sync_init warmer: that warmer runs its query inside a
      # spawned Task (`PhoenixKit.Cache.do_sync_warm/2`), which does not
      # inherit this test's :manual-mode Sandbox connection — triggering it
      # for real here would just fail to reach the database and prove
      # nothing. `test/phoenix_kit/utils/safe_destination_settings_test.exs`
      # seeds this same cache the same way, for the same reason.
      start_supervised!({PhoenixKit.Cache.Registry, []})
      start_supervised!({PhoenixKit.Cache, name: :settings})
      :ok = PhoenixKit.Cache.put_multiple(:settings, warmed)

      assert Settings.get_setting_cached("oauth_google_client_secret") ==
               "synthetic-cache-warm-secret"
    end

    test "an existing plaintext value is read back unchanged (legacy, not touched by this change)" do
      # Ecto.Changeset.change/2, not Setting.changeset/2, on purpose — this
      # is what an already-plaintext row from before this change looks
      # like, written directly rather than through the (encrypting) write
      # path this test is not exercising.
      {:ok, _} =
        %PhoenixKit.Settings.Setting{}
        |> Ecto.Changeset.change(%{
          key: "oauth_github_client_secret",
          value: "already-plaintext-legacy-value"
        })
        |> Queries.insert_setting()

      raw = Queries.get_setting_by_key("oauth_github_client_secret")
      refute String.starts_with?(raw.value, "enc:v1:")

      assert Settings.get_setting("oauth_github_client_secret") ==
               "already-plaintext-legacy-value"
    end

    # 🔴 The guard the card exists for: a secret that stops decrypting on
    # the read path must read as a broken login, never as a value — and
    # never as the raw enc:v1: ciphertext handed to whatever reads it next
    # (an OAuth strategy, AWS.access_key_id/0). This is the test that must
    # go red if a future change makes the read path fall back to the raw
    # stored value on a decrypt failure.
    test "the read path never returns raw ciphertext when decryption fails" do
      {:ok, _} =
        Settings.update_setting("oauth_google_client_secret", "synthetic-will-be-corrupted")

      raw = Queries.get_setting_by_key("oauth_google_client_secret")
      assert String.starts_with?(raw.value, "enc:v1:")

      # Simulate "the read path stopped decrypting" (mismatched/rotated key,
      # corrupted ciphertext) by corrupting the stored ciphertext directly —
      # via a bare Ecto.Changeset.change/2, bypassing Setting.changeset/2 on
      # purpose, so this writes the corrupted bytes as-is instead of the
      # write path re-encrypting them as if they were fresh plaintext.
      corrupted_ciphertext = String.slice(raw.value, 0..-6//1)

      {:ok, _} =
        raw
        |> Ecto.Changeset.change(value: corrupted_ciphertext)
        |> Queries.update_setting()

      PhoenixKit.Cache.invalidate(:settings, "oauth_google_client_secret")

      result = Settings.get_setting("oauth_google_client_secret")

      refute result == corrupted_ciphertext
      refute is_binary(result) and String.starts_with?(result, "enc:v1:")
      assert result == nil

      # Same guard through the plural read path OAuth login actually uses.
      PhoenixKit.Cache.invalidate(:settings, "oauth_google_client_secret")
      direct = Settings.get_settings_direct(["oauth_google_client_secret"])
      direct_value = Map.get(direct, "oauth_google_client_secret")

      refute direct_value == corrupted_ciphertext
      refute is_binary(direct_value) and String.starts_with?(direct_value, "enc:v1:")
    end
  end
end
