defmodule PhoenixKit.Utils.CountryDataTest do
  use ExUnit.Case, async: false

  # No `doctest` here: this module's examples are written against the bare
  # `CountryData.` alias, which a doctest has no way to resolve.

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
      assert length(CountryData.countries_for_select(locale: "ru")) ==
               length(CountryData.countries_for_select(locale: "en"))
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

      assert names == Enum.sort_by(names, &:unicode.characters_to_nfd_binary(String.downcase(&1)))
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
end
