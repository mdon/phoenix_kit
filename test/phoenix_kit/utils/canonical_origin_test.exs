defmodule PhoenixKit.Utils.CanonicalOriginTest.Resolver do
  @moduledoc false
  def host_for("en"), do: "en.example.test"
  def host_for("de"), do: "de.example.test"
  def host_for("blank"), do: "   "
  def host_for("padded"), do: "  padded.example.test  "
  def host_for("number"), do: 42
  def host_for("raise"), do: raise("boom")
  def host_for("exit"), do: exit(:boom)
  def host_for("sibling"), do: "sibling.example.test"
  def host_for(_), do: nil
end

defmodule PhoenixKit.Utils.CanonicalOriginTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Test.LanguageSettings
  alias PhoenixKit.Utils.CanonicalOriginTest.Resolver
  alias PhoenixKit.Utils.Routes

  setup do
    LanguageSettings.multilingual!()

    on_exit(fn -> Application.delete_env(:phoenix_kit, :canonical_host_resolver) end)

    %{base: Routes.base_url()}
  end

  defp resolver!,
    do: Application.put_env(:phoenix_kit, :canonical_host_resolver, {Resolver, :host_for})

  describe "canonical_host/1 without a usable resolver" do
    test "nil when no resolver is configured" do
      assert Routes.canonical_host("de") == nil
    end

    test "nil when the configured value is not an MFA pair" do
      Application.put_env(:phoenix_kit, :canonical_host_resolver, :nonsense)
      assert Routes.canonical_host("de") == nil
    end

    test "nil when the resolver module does not exist" do
      Application.put_env(:phoenix_kit, :canonical_host_resolver, {Missing.Module, :host_for})

      assert capture_log(fn -> assert Routes.canonical_host("de") == nil end) =~ "raised"
    end
  end

  describe "canonical_host/1 with a resolver" do
    setup do
      resolver!()
    end

    test "returns the host the resolver gives" do
      assert Routes.canonical_host("de") == "de.example.test"
    end

    test "calls the resolver with the base code of a dialect" do
      assert Routes.canonical_host("de-DE") == "de.example.test"
      assert Routes.canonical_host("EN-gb") == "en.example.test"
    end

    test "nil when the resolver has no host for the language" do
      assert Routes.canonical_host("uk") == nil
    end

    test "trims the host; blank is nil" do
      assert Routes.canonical_host("padded") == "padded.example.test"
      assert Routes.canonical_host("blank") == nil
    end

    test "a non-string answer is nil and is logged" do
      log = capture_log(fn -> assert Routes.canonical_host("number") == nil end)
      assert log =~ "non-string"
    end

    test "a resolver that raises is nil and is logged" do
      log = capture_log(fn -> assert Routes.canonical_host("raise") == nil end)
      assert log =~ "raised"
      assert log =~ "boom"
    end

    test "a resolver that exits is nil and is logged" do
      log = capture_log(fn -> assert Routes.canonical_host("exit") == nil end)
      assert log =~ "exited"
    end

    test "no language, blank language or a non-string language is nil" do
      assert Routes.canonical_host(nil) == nil
      assert Routes.canonical_host("") == nil
      assert Routes.canonical_host("  ") == nil
      assert Routes.canonical_host(:de) == nil
    end
  end

  describe "canonical_origin/1" do
    test "is https:// plus the host, or nil" do
      assert Routes.canonical_origin("de") == nil

      resolver!()
      assert Routes.canonical_origin("de") == "https://de.example.test"
      assert Routes.canonical_origin("de-DE") == "https://de.example.test"
      assert Routes.canonical_origin("uk") == nil
    end
  end

  describe "canonical_url/2" do
    test "without a host: the site base and the language-prefixed path", %{base: base} do
      assert Routes.canonical_url("/users/register", "de") ==
               base <> "/phoenix_kit/de/users/register"

      assert Routes.canonical_url("/users/register", "de-DE") ==
               base <> "/phoenix_kit/de/users/register"
    end

    test "with a host: the host and no language segment" do
      resolver!()

      assert Routes.canonical_url("/users/register", "de") ==
               "https://de.example.test/phoenix_kit/users/register"

      assert Routes.canonical_url("/users/register", "de-DE") ==
               "https://de.example.test/phoenix_kit/users/register"
    end

    test "a language without a host falls back to the site base", %{base: base} do
      resolver!()

      assert Routes.canonical_url("/users/register", "uk") ==
               base <> "/phoenix_kit/uk/users/register"
    end

    test "a failing resolver falls back to the site base", %{base: base} do
      resolver!()

      capture_log(fn ->
        assert Routes.canonical_url("/users/register", "raise") ==
                 base <> "/phoenix_kit/raise/users/register"

        assert Routes.canonical_url("/users/register", "exit") ==
                 base <> "/phoenix_kit/exit/users/register"
      end)
    end
  end

  describe "canonical_absolute/3 without a host" do
    test "keeps the built path as it is behind the site base", %{base: base} do
      assert Routes.canonical_absolute("/de/pages/home", "de") ==
               base <> "/de/pages/home"

      resolver!()

      assert Routes.canonical_absolute("/uk/pages/home", "uk") ==
               base <> "/uk/pages/home"
    end
  end

  describe "canonical_absolute/3 with a host" do
    setup do
      resolver!()
    end

    test "removes the language segment" do
      assert Routes.canonical_absolute("/de/pages/home", "de") ==
               "https://de.example.test/pages/home"
    end

    test "a dialect code removes the base segment, case-insensitively" do
      assert Routes.canonical_absolute("/de/pages/home", "de-DE") ==
               "https://de.example.test/pages/home"

      assert Routes.canonical_absolute("/DE/pages/home", "de-DE") ==
               "https://de.example.test/pages/home"
    end

    test "a dialect segment is removed too" do
      assert Routes.canonical_absolute("/de-de/pages/home", "de-DE") ==
               "https://de.example.test/pages/home"
    end

    test "keeps the mount prefix and removes the segment after it" do
      assert Routes.canonical_absolute("/phoenix_kit/de/users/log-in", "de") ==
               "https://de.example.test/phoenix_kit/users/log-in"
    end

    test "only a segment of the language is removed" do
      assert Routes.canonical_absolute("/en/pages/home", "de") ==
               "https://de.example.test/en/pages/home"

      assert Routes.canonical_absolute("/pages/de", "de") ==
               "https://de.example.test/pages/de"

      assert Routes.canonical_absolute("/deutsch/pages", "de") ==
               "https://de.example.test/deutsch/pages"
    end

    test "a path without a segment is left alone" do
      assert Routes.canonical_absolute("/pages/home", "de") ==
               "https://de.example.test/pages/home"
    end

    test "the bare language root becomes the root" do
      assert Routes.canonical_absolute("/de", "de") == "https://de.example.test/"
      assert Routes.canonical_absolute("/de?x=1", "de") == "https://de.example.test/?x=1"
      assert Routes.canonical_absolute("/de#top", "de") == "https://de.example.test/#top"
    end

    test "the query and fragment survive" do
      assert Routes.canonical_absolute("/de/pages/home?a=1#top", "de") ==
               "https://de.example.test/pages/home?a=1#top"
    end

    test ":segment names the only segment to remove" do
      assert Routes.canonical_absolute("/sibling/pages", "sibling", segment: "sibling") ==
               "https://sibling.example.test/pages"

      assert Routes.canonical_absolute("/en/pages", "en-GB", segment: "en-gb") ==
               "https://en.example.test/en/pages"

      assert Routes.canonical_absolute("/en-gb/pages", "en-GB", segment: "en-gb") ==
               "https://en.example.test/pages"
    end
  end
end
