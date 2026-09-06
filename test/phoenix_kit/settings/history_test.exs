defmodule PhoenixKit.Settings.HistoryTest do
  @moduledoc """
  Every change to a site setting is recorded, forever, with what it was
  before — so "what was this setting at that instant?" has an answer.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.History
  alias PhoenixKit.Settings.HistoryEntry
  alias PhoenixKit.Settings.Queries
  alias PhoenixKit.Settings.Setting
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  defp key, do: "history_test_#{System.unique_integer([:positive])}"

  defp entries(key), do: History.list(key) |> Enum.reverse()

  describe "recording" do
    test "a create records old nil, a change records both, an unchanged write records nothing" do
      key = key()

      {:ok, _} = Settings.update_setting(key, "2")
      {:ok, _} = Settings.update_setting(key, "2")
      {:ok, _} = Settings.update_setting(key, "Europe/Tallinn")

      assert [
               %HistoryEntry{old_value: nil, new_value: "2", source: "system", actor_uuid: nil},
               %HistoryEntry{old_value: "2", new_value: "Europe/Tallinn"}
             ] = entries(key)
    end

    test "the actor and source come from the writer's options" do
      key = key()

      {:ok, user} =
        Auth.register_user(%{
          email: "history-#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      {:ok, _} = Settings.update_setting(key, "a", actor_uuid: user.uuid, source: "settings")

      assert [%HistoryEntry{actor_uuid: actor, source: "settings"}] = entries(key)
      assert actor == user.uuid
    end

    test "the batch path and the settings page path record too, once per changed key" do
      a = key()
      b = key()
      {:ok, _} = Settings.update_setting(a, "old")

      {:ok, _} = Settings.update_settings_batch(%{a => "new", b => "first"}, source: "settings")

      assert [_, %HistoryEntry{old_value: "old", new_value: "new", source: "settings"}] =
               entries(a)

      assert [%HistoryEntry{old_value: nil, new_value: "first"}] = entries(b)

      # the admin page hands every key back on save; the unchanged ones stay silent
      {:ok, _} = Settings.update_settings_batch(%{a => "new", b => "first"}, source: "settings")
      assert length(entries(a)) == 2
      assert length(entries(b)) == 1
    end

    test "the module and boolean writers record" do
      key = key()
      {:ok, _} = Settings.update_boolean_setting_with_module(key, true, "test_module")
      {:ok, _} = Settings.update_boolean_setting_with_module(key, false, "test_module")

      assert [
               %HistoryEntry{old_value: nil, new_value: "true"},
               %HistoryEntry{old_value: "true", new_value: "false"}
             ] = entries(key)
    end

    test "a JSON setting records the encoded document, an empty one included" do
      key = key()
      {:ok, _} = Settings.update_json_setting(key, %{"a" => 1})
      {:ok, _} = Settings.update_json_setting(key, %{"a" => 2})
      {:ok, _} = Settings.update_json_setting(key, %{})

      assert [
               %HistoryEntry{old_value: nil, new_value: ~s({"a":1})},
               %HistoryEntry{old_value: ~s({"a":1}), new_value: ~s({"a":2})},
               %HistoryEntry{old_value: ~s({"a":2}), new_value: "{}"}
             ] = entries(key)
    end

    test "a restricted setting records that it changed, never the secret" do
      [restricted | _] = Settings.restricted_setting_keys()
      before = History.list(restricted)

      {:ok, _} =
        Settings.update_setting(restricted, "s3cret-#{System.unique_integer([:positive])}")

      [newest | _] = History.list(restricted)
      assert length(History.list(restricted)) == length(before) + 1
      assert %HistoryEntry{restricted: true, old_value: nil, new_value: nil} = newest
      refute Repo.all(HistoryEntry) |> Enum.any?(&(&1.new_value && &1.new_value =~ "s3cret"))
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

      assert [_, _, %HistoryEntry{old_value: "B", new_value: "C"}] = entries(key)
    end

    test "a history row that cannot be written fails the setting on the setting's changeset" do
      key = key()

      assert {:error, %Ecto.Changeset{data: %Setting{}} = changeset} =
               Settings.update_setting(key, "x", actor_uuid: Ecto.UUID.generate())

      assert changeset.errors[:base]
      assert Settings.get_setting(key) == nil
      assert History.list(key) == []
    end

    test "the batch result is the settings written, nothing else" do
      key = key()
      {:ok, changes} = Settings.update_settings_batch(%{key => "v"})
      assert Map.keys(changes) == [{:insert, key}]
    end

    test "the history row and the write land together" do
      key = key()
      # A key longer than the column allows fails the setting's own changeset;
      # nothing is recorded for it.
      long = String.duplicate("k", 300)
      assert {:error, _} = Settings.update_setting(long, "x")
      assert History.list(long) == []
      assert History.list(key) == []
    end

    test "deleting a user leaves the row, with the actor cleared" do
      key = key()

      {:ok, user} =
        Auth.register_user(%{
          email: "gone-#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      {:ok, _} = Settings.update_setting(key, "kept", actor_uuid: user.uuid)
      Repo.delete!(user)

      assert [%HistoryEntry{new_value: "kept", actor_uuid: nil}] = entries(key)
    end
  end

  describe "value_at/2" do
    test "walks the key's history: before any change, between changes, after the last" do
      key = key()
      {:ok, _} = Settings.update_setting(key, "0")
      [first] = History.list(key)

      Repo.update_all(from(h in HistoryEntry, where: h.uuid == ^first.uuid),
        set: [inserted_at: ~N[2026-08-01 10:00:00]]
      )

      {:ok, _} = Settings.update_setting(key, "Europe/Tallinn")
      [second, _] = History.list(key)

      Repo.update_all(from(h in HistoryEntry, where: h.uuid == ^second.uuid),
        set: [inserted_at: ~N[2026-09-01 10:00:00]]
      )

      # before the key existed: what the first change replaced (nothing)
      assert Settings.value_at(key, ~U[2026-07-01 00:00:00Z]) == nil
      # between the two changes: what the first set
      assert Settings.value_at(key, ~U[2026-08-15 00:00:00Z]) == "0"
      # at the exact instant of a change, that change counts
      assert Settings.value_at(key, ~U[2026-09-01 10:00:00Z]) == "Europe/Tallinn"
      assert Settings.value_at(key, ~U[2026-09-15 00:00:00Z]) == "Europe/Tallinn"
    end

    test "a key with no history has always been what it is now — a JSON one as its document" do
      key = key()
      assert Settings.value_at(key, ~U[2026-01-01 00:00:00Z]) == nil

      # written around the history (the table is the only writer, so
      # simulate a pre-history row by clearing what the write recorded)
      {:ok, _} = Settings.update_setting(key, "5.5")
      Repo.delete_all(from(h in HistoryEntry, where: h.key == ^key))
      assert Settings.value_at(key, ~U[2026-01-01 00:00:00Z]) == "5.5"

      json = key()
      {:ok, _} = Settings.update_json_setting(json, %{"a" => 1})
      Repo.delete_all(from(h in HistoryEntry, where: h.key == ^json))
      assert Settings.value_at(json, ~U[2026-01-01 00:00:00Z]) == ~s({"a":1})
    end

    test "an instant in another zone is the instant it names, not its wall clock" do
      key = key()
      {:ok, _} = Settings.update_setting(key, "before")
      [first] = History.list(key)

      Repo.update_all(from(h in HistoryEntry, where: h.uuid == ^first.uuid),
        set: [inserted_at: ~N[2026-08-01 10:00:00.000000]]
      )

      {:ok, _} = Settings.update_setting(key, "after")
      [second, _] = History.list(key)

      Repo.update_all(from(h in HistoryEntry, where: h.uuid == ^second.uuid),
        set: [inserted_at: ~N[2026-08-01 12:00:00.000000]]
      )

      # 13:00 at +02:00 is 11:00Z — between the two changes
      {:ok, plus_two} = DateTime.from_naive(~N[2026-08-01 13:00:00], "Etc/UTC")
      plus_two = %{plus_two | utc_offset: 7200, time_zone: "Etc/GMT-2", zone_abbr: "+02"}
      assert Settings.value_at(key, plus_two) == "before"
    end

    test "two changes inside one second keep their order" do
      key = key()
      {:ok, _} = Settings.update_setting(key, "1")
      {:ok, _} = Settings.update_setting(key, "2")
      {:ok, _} = Settings.update_setting(key, "3")
      [c, b, a] = History.list(key)
      assert NaiveDateTime.compare(a.inserted_at, b.inserted_at) == :lt
      assert NaiveDateTime.compare(b.inserted_at, c.inserted_at) == :lt
      assert Settings.value_at(key, b.inserted_at) == "2"
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
