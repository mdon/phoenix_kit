defmodule PhoenixKit.Utils.CountryDataTest do
  use ExUnit.Case, async: false

  # No `doctest` here: this module's examples are written against the bare
  # `CountryData.` alias, which a doctest has no way to resolve.

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Utils.CountryData

  setup do
    previous = Application.get_env(:phoenix_kit, :country_select_priority)
    on_exit(fn -> restore(:country_select_priority, previous) end)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:phoenix_kit, key)
  defp restore(key, value), do: Application.put_env(:phoenix_kit, key, value)

  defp by_code(entries), do: Map.new(entries, fn {display, code} -> {code, display} end)

  # The display name carries a flag emoji, which sorts by country code rather
  # than by name — compare the names the sort actually keys on.
  defp without_flag(display), do: display |> String.split(" ", parts: 2) |> List.last()

  describe "countries_for_select/1 locale" do
    test "translates names into the requested locale" do
      names = by_code(CountryData.countries_for_select(locale: "ru"))
      assert names["EE"] == "🇪🇪 Эстония"
      assert names["DE"] == "🇩🇪 Германия"
    end

    test "falls back to English for a locale with no translations" do
      names = by_code(CountryData.countries_for_select(locale: "xx"))
      assert names["EE"] == "🇪🇪 Estonia"
    end

    test "reduces a dialect to its base code" do
      assert CountryData.countries_for_select(locale: "ru-RU") ==
               CountryData.countries_for_select(locale: "ru")
    end

    test "keeps every country regardless of locale" do
      # Same country *codes*, not just the same count — a locale-dependent
      # filter bug could drop one country and pick up another while leaving
      # the length unchanged at 250.
      codes = fn locale ->
        CountryData.countries_for_select(locale: locale)
        |> Enum.map(&elem(&1, 1))
        |> MapSet.new()
      end

      assert codes.("ru") == codes.("en")
    end
  end

  describe "countries_for_select/1 priority" do
    test "pins the given codes to the top, in the order given" do
      result = CountryData.countries_for_select(locale: "en", priority: ["EE", "FI", "LV"])

      assert Enum.take(result, 3) == [
               {"🇪🇪 Estonia", "EE"},
               {"🇫🇮 Finland", "FI"},
               {"🇱🇻 Latvia", "LV"}
             ]
    end

    test "lists each pinned country exactly once" do
      codes =
        CountryData.countries_for_select(locale: "en", priority: ["EE", "FI"])
        |> Enum.map(&elem(&1, 1))

      assert Enum.count(codes, &(&1 == "EE")) == 1
      assert length(codes) == length(Enum.uniq(codes))
    end

    test "ignores unknown codes and normalizes case" do
      result = CountryData.countries_for_select(locale: "en", priority: ["zz", "ee"])
      assert hd(result) == {"🇪🇪 Estonia", "EE"}
    end

    test "defaults to the configured priority" do
      Application.put_env(:phoenix_kit, :country_select_priority, ["FI"])
      assert hd(CountryData.countries_for_select(locale: "en")) == {"🇫🇮 Finland", "FI"}
    end

    test "sorts the unpinned remainder alphabetically, accents folded" do
      names =
        CountryData.countries_for_select(locale: "en", priority: [])
        |> Enum.map(&without_flag(elem(&1, 0)))

      index = fn name -> Enum.find_index(names, &(&1 == name)) end

      # Literal neighbours from the real sorted (English) output, so that
      # changing the sort key breaks this test — unlike the previous version,
      # which re-derived the same NFD-fold-and-downcase key the implementation
      # uses and therefore could never fail. Folding places each accented name
      # next to its unaccented neighbours instead of exiling it past "Z".
      assert index.("Azerbaijan") < index.("Åland Islands")
      assert index.("Åland Islands") < index.("Bahamas")

      assert index.("Costa Rica") < index.("Côte d'Ivoire")
      assert index.("Côte d'Ivoire") < index.("Croatia")

      assert index.("Tuvalu") < index.("Türkiye")
      assert index.("Türkiye") < index.("Uganda")
    end

    test "sorts by the localized name, not the English one" do
      names =
        CountryData.countries_for_select(locale: "ru", priority: [])
        |> Enum.map(&without_flag(elem(&1, 0)))

      assert "Австралия" in names

      assert Enum.find_index(names, &(&1 == "Австралия")) <
               Enum.find_index(names, &(&1 == "Швеция"))
    end
  end

  describe "countries_for_select/1 priority from settings" do
    # The settings cache is consulted before the update-mode short-circuit, so
    # priming it exercises the real read path with no database involved. The
    # cache is a globally named process, hence async: false for the file.
    #
    # A cache MISS still falls through to `PhoenixKit.Settings`: with no
    # database `test_helper.exs` short-circuits that read to the default, but
    # when a database IS reachable it becomes a real query from a process
    # that owns no sandbox connection — an OwnershipError, not a miss.
    # Checking out here (copied from `safe_destination_settings_test.exs`,
    # which recorded the same failure on its first run against a database)
    # makes the file behave the same either way. Every test below primes the
    # key it reads except the "absent key" one, which is exactly why this
    # guard is needed at the describe level rather than per-test.
    setup do
      if Application.get_env(:phoenix_kit, :test_repo_available, false) do
        :ok = Sandbox.checkout(PhoenixKit.Test.Repo)
      end

      start_supervised!({PhoenixKit.Cache.Registry, []})
      start_supervised!({PhoenixKit.Cache, name: :settings})
      :ok
    end

    defp put_priority_setting(value),
      do: PhoenixKit.Cache.put(:settings, "country_select_priority", value)

    test "the setting wins over the config" do
      Application.put_env(:phoenix_kit, :country_select_priority, ["FI"])
      put_priority_setting("EE, LV")

      assert CountryData.countries_for_select(locale: "en") |> Enum.take(2) == [
               {"🇪🇪 Estonia", "EE"},
               {"🇱🇻 Latvia", "LV"}
             ]
    end

    test "a blank setting falls back to the config" do
      Application.put_env(:phoenix_kit, :country_select_priority, ["FI"])
      put_priority_setting("")

      assert hd(CountryData.countries_for_select(locale: "en")) == {"🇫🇮 Finland", "FI"}
    end

    test "an absent setting (never primed) falls back to the config" do
      Application.put_env(:phoenix_kit, :country_select_priority, ["FI"])
      # No put_priority_setting call: nothing was ever written for this key,
      # simulating a host that never opened the settings page — as distinct
      # from "a blank setting" above, which IS a written, empty row.

      assert hd(CountryData.countries_for_select(locale: "en")) == {"🇫🇮 Finland", "FI"}
    end

    test "an explicit :priority still overrides both" do
      Application.put_env(:phoenix_kit, :country_select_priority, ["FI"])
      put_priority_setting("EE")

      assert hd(CountryData.countries_for_select(locale: "en", priority: ["LV"])) ==
               {"🇱🇻 Latvia", "LV"}
    end

    test "a stored \"none\" sentinel beats the config" do
      Application.put_env(:phoenix_kit, :country_select_priority, ["FI"])
      put_priority_setting(CountryData.none_priority_value())

      assert CountryData.countries_for_select(locale: "en") ==
               CountryData.countries_for_select(locale: "en", priority: [])
    end

    test "the stored sentinel is recognized case-insensitively and trimmed" do
      Application.put_env(:phoenix_kit, :country_select_priority, ["FI"])
      unpinned = CountryData.countries_for_select(locale: "en", priority: [])

      for stored <- ["NONE", "None", " none ", "\tnone\n"] do
        put_priority_setting(stored)

        assert CountryData.countries_for_select(locale: "en") == unpinned
      end
    end
  end

  describe "parse_priority/1 and known_country_codes/1" do
    test "parses the separators an operator actually types" do
      assert CountryData.parse_priority("EE, FI ; lv") == ["EE", "FI", "LV"]
      assert CountryData.parse_priority("ee\nfi") == ["EE", "FI"]
      assert CountryData.parse_priority("EE, EE") == ["EE"]
      assert CountryData.parse_priority("") == []
      assert CountryData.parse_priority(nil) == []
    end

    test "drops codes that name no country" do
      assert CountryData.known_country_codes(["EE", "ZZ", "FI"]) == ["EE", "FI"]
      assert CountryData.known_country_codes(["", nil, :ee]) == []
    end

    test "a fully-rejected input keeps the unknown codes for reporting, but pins nothing" do
      # The scenario the settings form's flash has to report: every code the
      # operator typed is unknown, so nothing survives to be stored.
      typed = CountryData.parse_priority("Estonia, USA, Suomi")
      assert typed == ["ESTONIA", "USA", "SUOMI"]
      assert CountryData.known_country_codes(typed) == []
    end
  end

  describe "none_priority?/1 and none_priority_value/0" do
    test "recognizes the sentinel case-insensitively and trimmed" do
      assert CountryData.none_priority?("none")
      assert CountryData.none_priority?("NONE")
      assert CountryData.none_priority?("None")
      assert CountryData.none_priority?(" none ")
      assert CountryData.none_priority?("\tnone\n")
    end

    test "rejects everything else, including near-misses" do
      refute CountryData.none_priority?("EE")
      refute CountryData.none_priority?("")
      refute CountryData.none_priority?("none, EE")
      refute CountryData.none_priority?("noneEE")
      refute CountryData.none_priority?(nil)
      refute CountryData.none_priority?(:none)
    end

    test "the canonical value round-trips through the check" do
      assert CountryData.none_priority_value() == "none"
      assert CountryData.none_priority?(CountryData.none_priority_value())
    end

    test "the sentinel is not a real country code, so known_country_codes/1 would drop it" do
      # This is why the settings form must check `none_priority?/1` BEFORE
      # running the typed value through `parse_priority/1` and
      # `known_country_codes/1`: without that check, "none" is just another
      # unrecognized code and gets silently dropped like any other, storing
      # blank instead of the sentinel.
      refute CountryData.exists?(CountryData.none_priority_value())

      assert CountryData.none_priority_value()
             |> CountryData.parse_priority()
             |> CountryData.known_country_codes() == []
    end
  end

  describe "get_country_name/2" do
    test "translates into the requested locale" do
      assert CountryData.get_country_name("EE", locale: "ru") == "Эстония"
      assert CountryData.get_country_name("EE", locale: "en") == "Estonia"
    end

    test "falls back to the English name for an untranslated locale" do
      assert CountryData.get_country_name("EE", locale: "xx") == "Estonia"
    end

    test "still answers nil for an unknown country" do
      assert CountryData.get_country_name("XX") == nil
      assert CountryData.get_country_name(nil) == nil
    end

    test "keeps its one-argument shape for existing callers" do
      assert Code.ensure_loaded?(CountryData)
      assert function_exported?(CountryData, :get_country_name, 1)
      assert is_binary(CountryData.get_country_name("EE"))
    end
  end

  describe "eu_countries_for_select/1" do
    test "translates and pins like countries_for_select/1" do
      result = CountryData.eu_countries_for_select(locale: "ru", priority: ["EE"])
      assert hd(result) == {"🇪🇪 Эстония", "EE"}
      assert length(result) == 27
    end
  end

  describe "zero-arity contract" do
    test "countries_for_select/0 and eu_countries_for_select/0 stay exported" do
      # phoenix_kit_billing's core_compat lists
      # {CountryData, :countries_for_select, 0} as an unguarded runtime call
      # (lib/phoenix_kit_billing/core_compat.ex) — a regression here breaks
      # billing at boot. eu_countries_for_select/0 isn't in that list today,
      # but it shares the same `opts \\ []` contract, so it's asserted here
      # too rather than leaving it uncovered.
      #
      # function_exported?/3 answers false for a module that hasn't been
      # loaded yet, regardless of what it defines, so ensure_loaded? first.
      assert Code.ensure_loaded?(CountryData)
      assert function_exported?(CountryData, :countries_for_select, 0)
      assert function_exported?(CountryData, :eu_countries_for_select, 0)
    end

    test "countries_for_select/0 uses the active Gettext locale when :locale is omitted" do
      previous = Gettext.get_locale(PhoenixKitWeb.Gettext)
      on_exit(fn -> Gettext.put_locale(PhoenixKitWeb.Gettext, previous) end)

      Gettext.put_locale(PhoenixKitWeb.Gettext, "ru")

      names = by_code(CountryData.countries_for_select())
      assert names["EE"] == "🇪🇪 Эстония"
    end
  end
end
