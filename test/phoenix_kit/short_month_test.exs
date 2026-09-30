defmodule PhoenixKit.ShortMonthTest do
  @moduledoc """
  `Calendar.strftime/2`'s `%b` is locale-blind — it yields English month
  abbreviations no matter what Gettext locale is active. The media viewer's
  "Uploaded:" line used it directly, and every localized module rebuilt the same
  twelve-entry gettext table rather than share one.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Utils.Date, as: UtilsDate

  setup do
    previous = Gettext.get_locale(PhoenixKitWeb.Gettext)
    on_exit(fn -> Gettext.put_locale(PhoenixKitWeb.Gettext, previous) end)
    :ok
  end

  describe "short_month/1" do
    test "covers all twelve months" do
      for month <- 1..12 do
        assert is_binary(UtilsDate.short_month(month))
        assert UtilsDate.short_month(month) != ""
      end
    end

    test "reads the active locale, not the system's" do
      # The strings already exist in core's catalog with et/ru translations —
      # they were carried purely as an extraction anchor for phoenix_kit_projects.
      Gettext.put_locale(PhoenixKitWeb.Gettext, "en")
      english = Enum.map(1..12, &UtilsDate.short_month/1)

      Gettext.put_locale(PhoenixKitWeb.Gettext, "et")
      estonian = Enum.map(1..12, &UtilsDate.short_month/1)

      assert english != estonian,
             "et translations exist in the catalog; identical output means the lookup is not " <>
               "reaching Gettext"
    end
  end

  describe "format_short_datetime/1" do
    test "renders the month through the locale rather than strftime" do
      Gettext.put_locale(PhoenixKitWeb.Gettext, "en")
      dt = ~U[2026-03-09 07:05:00Z]

      assert UtilsDate.format_short_datetime(dt) == "Mar 09, 2026 at 07:05"
    end

    test "a nil datetime renders as empty rather than crashing a page" do
      assert UtilsDate.format_short_datetime(nil) == ""
    end
  end

  describe "short/1 and short_with_year/1" do
    test "English: day, month abbreviation, year" do
      Gettext.put_locale(PhoenixKitWeb.Gettext, "en")
      assert UtilsDate.short(~D[2026-10-03]) == "3 Oct"
      assert UtilsDate.short_with_year(~D[2026-10-03]) == "3 Oct 2026"
      assert UtilsDate.short_with_year(~U[2026-12-25 10:00:00Z]) == "25 Dec 2026"
      assert UtilsDate.short_with_year(~N[2026-01-09 08:00:00]) == "9 Jan 2026"
    end

    test "nil renders as an empty string" do
      assert UtilsDate.short(nil) == ""
      assert UtilsDate.short_with_year(nil) == ""
    end
  end
end
