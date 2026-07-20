defmodule PhoenixKit.Settings.TimezoneLabelTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Settings

  describe "timezone_options/0" do
    test "is a non-empty list of {label, value} tuples covering the known offsets" do
      options = Settings.timezone_options()

      assert [_ | _] = options

      assert Enum.all?(
               options,
               &match?({label, value} when is_binary(label) and is_binary(value), &1)
             )

      assert {"UTC+0 (London, Dublin, Lisbon, Accra)", "0"} in options
      assert {"UTC-5 (New York, Toronto, Bogotá, Lima)", "-5"} in options
      assert {"UTC+5:30 (Mumbai, Delhi, Kolkata, Colombo)", "5.5"} in options
    end

    test "is the same list get_setting_options/0 uses for \"time_zone\"" do
      assert Settings.timezone_options() == Settings.get_setting_options()["time_zone"]
    end
  end

  describe "get_timezone_label/1 (cheap path)" do
    test "resolves a positive offset" do
      assert Settings.get_timezone_label("8") == "UTC+8 (Beijing, Singapore, Hong Kong, Perth)"
    end

    test "resolves a negative offset" do
      assert Settings.get_timezone_label("-5") == "UTC-5 (New York, Toronto, Bogotá, Lima)"
    end

    test "resolves the zero offset" do
      assert Settings.get_timezone_label("0") == "UTC+0 (London, Dublin, Lisbon, Accra)"
    end

    test "resolves a half-hour offset" do
      assert Settings.get_timezone_label("5.5") ==
               "UTC+5:30 (Mumbai, Delhi, Kolkata, Colombo)"
    end

    test "falls back to a bare UTC label for a value not in the list" do
      assert Settings.get_timezone_label("99") == "UTC99"
      assert Settings.get_timezone_label("-3.25") == "UTC-3.25"
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
      query_count = count_repo_queries(fn -> Settings.get_timezone_label("3") end)

      assert query_count == 0
    end
  end

  describe "get_timezone_label/2 (backward-compatible path)" do
    test "still resolves against a real get_setting_options/0 map" do
      assert Settings.get_timezone_label("0", Settings.get_setting_options()) ==
               "UTC+0 (London, Dublin, Lisbon, Accra)"
    end

    test "falls back to timezone_options/0 if the given map has no \"time_zone\" key" do
      assert Settings.get_timezone_label("0", %{}) == "UTC+0 (London, Dublin, Lisbon, Accra)"
    end

    test "falls back to a bare UTC label for an unknown value" do
      assert Settings.get_timezone_label("42", Settings.get_setting_options()) == "UTC42"
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
