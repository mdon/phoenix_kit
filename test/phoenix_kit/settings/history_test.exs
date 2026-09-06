defmodule PhoenixKit.Settings.HistoryTest do
  @moduledoc """
  Every change to a site setting is recorded as a permanent activity entry
  with what it was before — so "what was this setting at that instant?" has
  an answer, and the pruner never takes it.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Activity
  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.History
  alias PhoenixKit.Settings.Queries
  alias PhoenixKit.Settings.Setting
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  defp key, do: "history_test_#{System.unique_integer([:positive])}"

  # oldest first, as {from, to}
  defp changes(key),
    do:
      key
      |> History.list()
      |> Enum.reverse()
      |> Enum.map(&{&1.metadata["from"], &1.metadata["to"]})

  defp set_time(%Entry{uuid: uuid}, %DateTime{} = at) do
    Repo.update_all(from(e in Entry, where: e.uuid == ^uuid), set: [inserted_at: at])
  end

  describe "recording" do
    test "a create records old nil, a change records both, an unchanged write records nothing" do
      key = key()

      {:ok, _} = Settings.update_setting(key, "2")
      {:ok, _} = Settings.update_setting(key, "2")
      {:ok, _} = Settings.update_setting(key, "Europe/Tallinn")

      assert changes(key) == [{nil, "2"}, {"2", "Europe/Tallinn"}]

      [newest | _] = History.list(key)
      assert %Entry{action: "setting.changed", resource_type: "setting", permanent: true} = newest
      assert newest.metadata["key"] == key
      assert newest.metadata["source"] == "system"
      assert newest.mode == "system"
      assert newest.actor_uuid == nil
    end

    test "the actor and source come from the writer's options" do
      key = key()

      {:ok, user} =
        Auth.register_user(%{
          email: "history-#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      {:ok, _} = Settings.update_setting(key, "a", actor_uuid: user.uuid, source: "settings")

      assert [%Entry{actor_uuid: actor, mode: "manual", metadata: %{"source" => "settings"}}] =
               History.list(key)

      assert actor == user.uuid
    end

    test "the batch path records too, once per changed key, and returns the settings only" do
      a = key()
      b = key()
      {:ok, _} = Settings.update_setting(a, "old")

      {:ok, changes} =
        Settings.update_settings_batch(%{a => "new", b => "first"}, source: "settings")

      assert Map.keys(changes) |> Enum.sort() == Enum.sort([{:update, a}, {:insert, b}])
      assert changes(a) == [{nil, "old"}, {"old", "new"}]
      assert changes(b) == [{nil, "first"}]

      # the admin page hands every key back on save; the unchanged ones stay silent
      {:ok, _} = Settings.update_settings_batch(%{a => "new", b => "first"}, source: "settings")
      assert length(changes(a)) == 2
      assert length(changes(b)) == 1
    end

    test "the module and boolean writers record" do
      key = key()
      {:ok, _} = Settings.update_boolean_setting_with_module(key, true, "test_module")
      {:ok, _} = Settings.update_boolean_setting_with_module(key, false, "test_module")
      assert changes(key) == [{nil, "true"}, {"true", "false"}]
    end

    test "a JSON setting records the encoded document, an empty one included" do
      key = key()
      {:ok, _} = Settings.update_json_setting(key, %{"a" => 1})
      {:ok, _} = Settings.update_json_setting(key, %{"a" => 2})
      {:ok, _} = Settings.update_json_setting(key, %{})

      assert changes(key) == [
               {nil, ~s({"a":1})},
               {~s({"a":1}), ~s({"a":2})},
               {~s({"a":2}), "{}"}
             ]
    end

    test "a restricted setting records that it changed, never the secret" do
      [restricted | _] = Settings.restricted_setting_keys()
      before = History.list(restricted)
      secret = "s3cret-#{System.unique_integer([:positive])}"

      {:ok, _} = Settings.update_setting(restricted, secret)

      [newest | _] = History.list(restricted)
      assert length(History.list(restricted)) == length(before) + 1
      assert %{"restricted" => true, "from" => nil, "to" => nil} = newest.metadata
      refute Repo.all(Entry) |> Enum.any?(&(inspect(&1.metadata) =~ secret))
    end

    test "the old value is what the row holds when the write commits, not what the caller read" do
      key = key()
      {:ok, _} = Settings.update_setting(key, "A")

      # A concurrent writer moved the row to "B" between this caller's read
      # and its write: the history must say B → C, never A → C.
      stale = Repo.get_by!(Setting, key: key)
      {:ok, _} = Settings.update_setting(key, "B")

      {:ok, _} =
        stale
        |> Setting.update_changeset(%{value: "C"})
        |> Queries.update_setting()

      assert changes(key) == [{nil, "A"}, {"A", "B"}, {"B", "C"}]
    end

    test "a setting whose own changeset fails records nothing" do
      long = String.duplicate("k", 300)
      assert {:error, _} = Settings.update_setting(long, "x")
      assert History.list(long) == []
    end

    test "deleting the actor leaves the entry — the feed keeps who did it" do
      key = key()

      {:ok, user} =
        Auth.register_user(%{
          email: "gone-#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      {:ok, _} = Settings.update_setting(key, "kept", actor_uuid: user.uuid)
      Repo.delete!(user)

      # The feed's actor reference is deliberately unconstrained (the doctor
      # task lists it as the known gap), so the entry keeps the uuid.
      assert [%Entry{actor_uuid: actor, metadata: %{"to" => "kept"}}] = History.list(key)
      assert actor == user.uuid
    end
  end

  describe "permanence" do
    test "the pruner keeps a settings change and drops an ordinary entry of the same age" do
      key = key()
      {:ok, _} = Settings.update_setting(key, "kept")
      [kept] = History.list(key)

      {:ok, ordinary} = Activity.log(%{action: "test.pruned"})
      old = DateTime.add(DateTime.utc_now(), -400 * 86_400, :second)
      set_time(kept, old)
      set_time(ordinary, old)

      {:ok, _count} = Activity.prune(365)

      assert Repo.get(Entry, kept.uuid)
      refute Repo.get(Entry, ordinary.uuid)
    end

    test "two changes inside one second keep their order" do
      key = key()
      {:ok, _} = Settings.update_setting(key, "1")
      {:ok, _} = Settings.update_setting(key, "2")
      {:ok, _} = Settings.update_setting(key, "3")
      [c, b, a] = History.list(key)
      assert DateTime.compare(a.inserted_at, b.inserted_at) == :lt
      assert DateTime.compare(b.inserted_at, c.inserted_at) == :lt
      assert Settings.value_at(key, b.inserted_at) == "2"
    end
  end

  describe "value_at/2" do
    test "walks the key's history: before any change, between changes, at one, after the last" do
      key = key()
      {:ok, _} = Settings.update_setting(key, "0")
      [first] = History.list(key)
      set_time(first, ~U[2026-08-01 10:00:00.000000Z])

      {:ok, _} = Settings.update_setting(key, "Europe/Tallinn")
      [second, _] = History.list(key)
      set_time(second, ~U[2026-09-01 10:00:00.000000Z])

      # before the key existed: what the first change replaced (nothing)
      assert Settings.value_at(key, ~U[2026-07-01 00:00:00Z]) == nil
      # between the two changes: what the first set
      assert Settings.value_at(key, ~U[2026-08-15 00:00:00Z]) == "0"
      # at the exact instant of a change, that change counts
      assert Settings.value_at(key, ~U[2026-09-01 10:00:00Z]) == "Europe/Tallinn"
      assert Settings.value_at(key, ~U[2026-09-15 00:00:00Z]) == "Europe/Tallinn"
      # a NaiveDateTime is read as UTC
      assert Settings.value_at(key, ~N[2026-08-15 00:00:00]) == "0"
    end

    test "an instant in another zone is the instant it names, not its wall clock" do
      key = key()
      {:ok, _} = Settings.update_setting(key, "before")
      [first] = History.list(key)
      set_time(first, ~U[2026-08-01 10:00:00.000000Z])

      {:ok, _} = Settings.update_setting(key, "after")
      [second, _] = History.list(key)
      set_time(second, ~U[2026-08-01 12:00:00.000000Z])

      # 13:00 at +02:00 is 11:00Z — between the two changes
      {:ok, plus_two} = DateTime.from_naive(~N[2026-08-01 13:00:00], "Etc/UTC")
      plus_two = %{plus_two | utc_offset: 7200, time_zone: "Etc/GMT-2", zone_abbr: "+02"}
      assert Settings.value_at(key, plus_two) == "before"
    end

    test "a key with no history has always been what it is now — a JSON one as its document" do
      key = key()
      assert Settings.value_at(key, ~U[2026-01-01 00:00:00Z]) == nil

      # written around the history (the feed is the only writer, so simulate
      # a pre-history row by clearing what the write recorded)
      {:ok, _} = Settings.update_setting(key, "5.5")
      Repo.delete_all(from(e in Entry, where: fragment("? ->> 'key' = ?", e.metadata, ^key)))
      assert Settings.value_at(key, ~U[2026-01-01 00:00:00Z]) == "5.5"

      json = key()
      {:ok, _} = Settings.update_json_setting(json, %{"a" => 1})
      Repo.delete_all(from(e in Entry, where: fragment("? ->> 'key' = ?", e.metadata, ^json)))
      assert Settings.value_at(json, ~U[2026-01-01 00:00:00Z]) == ~s({"a":1})
    end

    test "a restricted key answers nil for every instant, history or not" do
      [restricted | _] = Settings.restricted_setting_keys()

      {:ok, _} =
        Settings.update_setting(restricted, "s3cret-#{System.unique_integer([:positive])}")

      assert Settings.value_at(restricted, DateTime.utc_now()) == nil
      assert Settings.value_at(restricted, ~U[2000-01-01 00:00:00Z]) == nil
    end
  end
end
