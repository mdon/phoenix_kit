defmodule PhoenixKit.Settings.TimezoneLabelTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.TimeZone

  describe "timezone_options/0" do
    test "is a non-empty list of {label, value} tuples covering the known offsets" do
      options = Settings.timezone_options()

      assert [_ | _] = options

      assert Enum.all?(
               options,
               &match?({label, value} when is_binary(label) and is_binary(value), &1)
             )

      # Identifiers, not offsets. The offset in the label is computed now, so
      # only the id half is safe to pin — the other half moves with DST, which
      # is the entire point of the change.
      ids = Enum.map(options, fn {_label, id} -> id end)

      # Values are group representatives, not every zone — the list is 59 rows,
      # not 447. Warsaw is reachable through the row it belongs to.
      assert Enum.all?(ids, &TimeZone.representative?/1)
      assert TimeZone.group_for("Europe/Warsaw") in ids
      assert TimeZone.group_for("America/New_York") in ids
      assert TimeZone.group_for("Asia/Kolkata") in ids
    end

    test "is the same list get_setting_options/0 uses for \"time_zone\"" do
      assert Settings.timezone_options() == Settings.get_setting_options()["time_zone"]
    end
  end

  describe "get_timezone_label/1 (cheap path)" do
    test "resolves an identifier, with its offset as of now" do
      assert Settings.get_timezone_label("Europe/Warsaw") =~ "Europe/Warsaw"
      assert Settings.get_timezone_label("Europe/Warsaw") =~ ~r/\(UTC[+-]\d\d:\d\d\)/
    end

    test "resolves a legacy positive offset" do
      assert Settings.get_timezone_label("8") == "UTC+08:00"
    end

    test "resolves a negative offset" do
      assert Settings.get_timezone_label("-5") == "UTC-05:00"
    end

    test "resolves the zero offset" do
      assert Settings.get_timezone_label("0") == "UTC+00:00"
    end

    test "resolves a legacy half-hour offset" do
      assert Settings.get_timezone_label("5.5") == "UTC+05:30"
    end

    test "returns an unrecognisable value verbatim rather than dressing it up" do
      # "UTC99" read like a real zone. Echoing the stored value makes a bad
      # row look like what it is.
      assert Settings.get_timezone_label("99") == "99"
      assert Settings.get_timezone_label("nonsense") == "nonsense"
    end

    test "blank means the system default" do
      assert Settings.get_timezone_label(nil) == "Use System Default"
      assert Settings.get_timezone_label("") == "Use System Default"
    end

    test "agrees with the existing get_timezone_label/2 for every listed offset" do
      full_options = Settings.get_setting_options()

      for {_label, value} <- Settings.timezone_options() do
        assert Settings.get_timezone_label(value) ==
                 Settings.get_timezone_label(value, full_options)
      end
    end

    # This is the actual point of the change: get_timezone_label/2 needs
    # the whole get_setting_options/0 map, which builds "new_user_default_role"
    # via get_role_options/0 → Roles.list_roles/0 — a real query, paid on
    # every call site that only wanted the timezone label (mount/3 of
    # PhoenixKitWeb.Live.Modules.Maintenance.Settings, among others).
    # get_timezone_label/1 must never touch the database at all.
    test "never issues a repo query — proves it doesn't build the full options map" do
      query_count = count_repo_queries(fn -> Settings.get_timezone_label("Europe/Warsaw") end)

      assert query_count == 0
    end
  end

  describe "get_timezone_label/2 (backward-compatible path)" do
    test "still resolves against a real get_setting_options/0 map" do
      assert Settings.get_timezone_label("Europe/Warsaw", Settings.get_setting_options()) =~
               "Europe/Warsaw"
    end

    test "falls back to timezone_options/0 if the given map has no \"time_zone\" key" do
      assert Settings.get_timezone_label("0", %{}) == "UTC+00:00"
    end

    test "returns an unknown value verbatim" do
      assert Settings.get_timezone_label("42", Settings.get_setting_options()) == "42"
    end
  end

  # Counts Ecto query telemetry events fired on this process while running
  # `fun` — proves get_timezone_label/1 resolves purely in-memory. Mirrors
  # the pattern already used in phoenix_kit_crm's import_test.exs.
  #
  # :telemetry.attach is process-global, not scoped to the caller — under
  # async: true, other tests' concurrently-running queries fire the same
  # event and would inflate the count. Telemetry handlers run synchronously
  # in whichever process executes :telemetry.execute (i.e. whichever
  # process issued the query), so filtering on self() inside the handler
  # isolates counts to queries issued by this test's own process.
  #
  # The event name below is not the conventional [otp_app, :repo, :query]
  # — Ecto derives its telemetry prefix from the REPO MODULE's own name
  # (Module.split/1, underscored), not the OTP app. This suite's repo is
  # PhoenixKit.Test.Repo, so the prefix is [:phoenix_kit, :test, :repo],
  # and the query event is that prefix with :query appended.
  defp count_repo_queries(fun) do
    handler_id = "count-repo-queries-#{inspect(self())}-#{System.unique_integer()}"
    counter = :counters.new(1, [])
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:phoenix_kit, :test, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    :counters.get(counter, 1)
  end
end
