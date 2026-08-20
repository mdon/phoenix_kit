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
end
