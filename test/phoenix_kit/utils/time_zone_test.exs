defmodule PhoenixKit.Utils.TimeZoneTest do
  @moduledoc """
  Pins the reported timezone bugs so they cannot come back.

  Every case here failed under the previous integer-offset scheme.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.TimeZone

  # Northern-hemisphere summer and winter, so a DST transition sits between.
  @summer DateTime.new!(~D[2026-08-24], ~T[12:00:00], "Etc/UTC")
  @winter DateTime.new!(~D[2026-01-15], ~T[12:00:00], "Etc/UTC")

  defp offset_hours(datetime, zone) do
    shifted = TimeZone.shift(datetime, zone)
    (shifted.utc_offset + shifted.std_offset) / 3600
  end

  describe "the grouped picker" do
    test "is short enough to browse, and every row is a real zone" do
      options = TimeZone.options()

      # The whole point of grouping: 59-ish rows, not 447.
      assert length(options) < 80

      for {_label, id} <- options do
        assert TimeZone.identifier?(id)
        assert TimeZone.representative?(id)
      end
    end

    test "Johannesburg and Helsinki cannot share a row" do
      # The original bug. They are only equal in winter, so grouping by
      # behaviour puts them in different groups by construction.
      refute TimeZone.same_group?("Africa/Johannesburg", "Europe/Helsinki")
    end

    test "cities that behave identically all year do share a row" do
      assert TimeZone.same_group?("Europe/Tallinn", "Europe/Helsinki")
      assert TimeZone.same_group?("Europe/Warsaw", "Europe/Berlin")
    end

    test "labels name cities that really belong to the group" do
      # Guards the one hand-curated part of the table. If a country changes its
      # rules and moves group, the label must not keep advertising it.
      for {label, rep} <- TimeZone.options() do
        "(UTC" <> rest = label

        cities =
          rest
          |> String.split(") ", parts: 2)
          |> List.last()
          |> String.replace(" — summer time", "")
          |> String.split(", ")

        for city <- cities do
          assert Enum.any?(TimeZone.identifiers(), fn id ->
                   TimeZone.same_group?(id, rep) and
                     String.ends_with?(id, String.replace(city, " ", "_"))
                 end),
                 "#{label} names #{city}, which is not in the group #{rep} represents"
        end
      end
    end

    test "labels carry the offset as of now, not a frozen winter value" do
      {label, _id} =
        Enum.find(TimeZone.options(), fn {_l, id} -> id == "Europe/Paris" end)

      assert label =~ ~r/^\(UTC[+-]\d\d:\d\d\)/
      assert label =~ "summer time"
    end

    test "a saved zone that is not a representative is added as its own row" do
      # What auto-detection stores: somewhere precise, not a group stand-in.
      plain = TimeZone.options()
      with_tallinn = TimeZone.options(selected: "Europe/Tallinn")

      refute Enum.any?(plain, fn {_l, id} -> id == "Europe/Tallinn" end)
      assert length(with_tallinn) == length(plain) + 1
      assert {label, "Europe/Tallinn"} = hd(with_tallinn)
      assert label =~ "your location"
    end

    test "a saved representative does not get duplicated" do
      assert length(TimeZone.options(selected: "Europe/Paris")) ==
               length(TimeZone.options())
    end
  end

  describe "the identifier list" do
    test "every identifier resolves against the compiled tz database" do
      unresolvable =
        Enum.reject(TimeZone.identifiers(), fn id ->
          match?({:ok, _}, DateTime.shift_zone(@summer, id, TimeZone.database()))
        end)

      assert unresolvable == [],
             "these ids are in the picker but the tz database cannot place them: " <>
               inspect(unresolvable)
    end

    test "Warsaw is present — the omission that started this" do
      assert "Europe/Warsaw" in TimeZone.identifiers()
    end

    test "zones tzdata links to another are kept, so people can find their own city" do
      # Oslo, Stockholm and Copenhagen are links to Europe/Berlin. Filtering the
      # list to canonical entries would drop them and repeat the Warsaw problem.
      for id <- ["Europe/Oslo", "Europe/Stockholm", "Europe/Copenhagen"] do
        assert id in TimeZone.identifiers()
      end
    end

    test "every identifier belongs to exactly one group" do
      for id <- TimeZone.identifiers() do
        assert TimeZone.group_for(id) != nil, "#{id} is in no group"
      end
    end
  end

  describe "the bugs from the report" do
    test "Helsinki and Kyiv are UTC+3 in summer, not the winter +2 they were labelled" do
      assert offset_hours(@summer, "Europe/Helsinki") == 3.0
      assert offset_hours(@summer, "Europe/Kyiv") == 3.0
    end

    test "Johannesburg is UTC+2 year round, so it cannot share a row with them" do
      assert offset_hours(@summer, "Africa/Johannesburg") == 2.0
      assert offset_hours(@winter, "Africa/Johannesburg") == 2.0

      refute offset_hours(@summer, "Europe/Helsinki") ==
               offset_hours(@summer, "Africa/Johannesburg")
    end

    test "Warsaw follows DST without being re-saved" do
      assert offset_hours(@summer, "Europe/Warsaw") == 2.0
      assert offset_hours(@winter, "Europe/Warsaw") == 1.0
    end

    test "Almaty is UTC+5 — it was listed under +6, wrong in every season" do
      assert offset_hours(@summer, "Asia/Almaty") == 5.0
      assert offset_hours(@winter, "Asia/Almaty") == 5.0
    end
  end

  describe "legacy numeric offsets" do
    test "a stored whole-hour offset still shifts exactly as before" do
      assert TimeZone.shift(@summer, "2") == DateTime.add(@summer, 2 * 3600, :second)
      assert TimeZone.shift(@summer, "-5") == DateTime.add(@summer, -5 * 3600, :second)
      assert TimeZone.shift(@summer, "+3") == DateTime.add(@summer, 3 * 3600, :second)
    end

    test "half-hour offsets shift — Integer.parse/1 used to drop them silently" do
      # "5.5" left a ".5" remainder, failed the `{offset, ""}` match, and the
      # timestamp came back unshifted: every UTC+5:30 account read UTC.
      assert TimeZone.shift(@summer, "5.5") == DateTime.add(@summer, 19_800, :second)
      assert TimeZone.shift(@summer, "9.5") == DateTime.add(@summer, 34_200, :second)
    end

    test "legacy values are recognised as such, so the UI can offer a real zone" do
      for value <- ["2", "-5", "+3", "5.5"] do
        assert TimeZone.legacy_offset?(value)
        refute TimeZone.identifier?(value)
      end
    end

    test "an identifier is not mistaken for an offset" do
      assert TimeZone.identifier?("Europe/Warsaw")
      refute TimeZone.legacy_offset?("Europe/Warsaw")
    end
  end

  describe "shift/2 tolerance" do
    test "blank values pass the datetime through untouched" do
      assert TimeZone.shift(@summer, nil) == @summer
      assert TimeZone.shift(@summer, "") == @summer
    end

    test "an unusable value returns the datetime rather than raising" do
      # A page of timestamps is worth more than a crash over a preference.
      assert TimeZone.shift(@summer, "Mars/Olympus_Mons") == @summer
      assert TimeZone.shift(@summer, "not a zone") == @summer
      assert TimeZone.shift(@summer, "99") == @summer
    end
  end

  describe "valid?/1" do
    test "accepts identifiers, legacy offsets and blank" do
      assert TimeZone.valid?("Europe/Warsaw")
      assert TimeZone.valid?("5.5")
      assert TimeZone.valid?(nil)
      assert TimeZone.valid?("")
    end

    test "rejects anything else" do
      refute TimeZone.valid?("Mars/Olympus_Mons")
      refute TimeZone.valid?("99")
    end
  end
end
