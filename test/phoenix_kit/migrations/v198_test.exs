defmodule PhoenixKit.Migrations.Postgres.V198Test do
  @moduledoc """
  V198 withholds the secret-named setting values the settings history already
  recorded, run against seeded activity entries.

  Until the writer learned to read a key's NAME the way the change broadcast
  does, a module's `…_api_key` written through the ordinary writers was stored
  in a permanent `setting.changed` entry in plain text. The suite's writer no
  longer does this, so the entries are seeded the way the old writer wrote
  them, and the migration's real statements run against them (`up/1` and
  `down/1` execute exactly `up_statements/1` and `down_statements/1`).
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V198
  alias PhoenixKit.Settings.Events
  alias PhoenixKit.Test.Repo

  defp run_up, do: Enum.each(V198.up_statements("public."), &Repo.query!/1)
  defp run_down, do: Enum.each(V198.down_statements("public."), &Repo.query!/1)

  # An entry as the old writer recorded it: both values in full.
  defp entry!(key, metadata \\ %{}, action \\ "setting.changed") do
    metadata =
      Map.merge(
        %{"key" => key, "from" => "old-value", "to" => "new-value", "restricted" => false},
        metadata
      )

    %{rows: [[uuid]]} =
      Repo.query!(
        """
        INSERT INTO phoenix_kit_activities
          (action, mode, resource_type, resource_uuid, permanent, metadata)
        VALUES ($1, 'system', 'setting', $2, true, $3)
        RETURNING uuid
        """,
        [action, Ecto.UUID.dump!(Ecto.UUID.generate()), metadata]
      )

    uuid
  end

  defp metadata(entry_uuid) do
    %{rows: [[metadata]]} =
      Repo.query!("SELECT metadata FROM phoenix_kit_activities WHERE uuid = $1", [entry_uuid])

    metadata
  end

  defp withheld?(metadata) do
    metadata["from"] == nil and metadata["to"] == nil and metadata["restricted"] == true
  end

  defp marker do
    %{rows: [[marker]]} = Repo.query!("SELECT obj_description('phoenix_kit'::regclass)")
    marker
  end

  test "a secret-named key loses its values and keeps the rest" do
    entry = entry!("comments_giphy_api_key", %{"source" => "settings"})

    run_up()

    metadata = metadata(entry)
    assert withheld?(metadata)
    assert metadata["key"] == "comments_giphy_api_key", "which setting changed is still recorded"
    assert metadata["source"] == "settings"
  end

  test "every fragment the writer tests for is withheld, in any case" do
    entries =
      for fragment <- V198.fragments() do
        entry!("Probe_#{String.upcase(fragment)}_v198")
      end

    run_up()

    assert Enum.all?(entries, &(&1 |> metadata() |> withheld?()))
  end

  # The list is frozen in the migration. If the writer's grows, entries the
  # old writer stored under the new fragment need a version of their own —
  # this is the reminder.
  test "the frozen list still covers every key the writer withholds by name" do
    for fragment <- V198.fragments() do
      assert Events.secret_key?("probe_#{fragment}_v198")
    end

    refute Events.secret_key?("site_url_v198_probe")
  end

  test "ordinary settings keep their history" do
    entry =
      entry!("site_url_v198_probe", %{"from" => "https://old.test", "to" => "https://new.test"})

    run_up()

    metadata = metadata(entry)
    assert metadata["from"] == "https://old.test"
    assert metadata["to"] == "https://new.test"
    assert metadata["restricted"] == false
  end

  test "other actions are never touched, even with a secret-shaped key" do
    entry = entry!("some_api_key", %{"from" => "kept", "to" => "kept"}, "integration.connected")

    run_up()

    assert metadata(entry)["from"] == "kept"
  end

  test "re-runnable: an entry already withheld is left exactly as it is" do
    entry = entry!("some_api_key", %{"from" => nil, "to" => nil, "restricted" => true, "x" => 1})

    version = row_version(entry)
    run_up()

    assert row_version(entry) == version, "the row was not rewritten"
    assert metadata(entry)["x"] == 1
  end

  # A row's xmin changes whenever an UPDATE rewrites it, even to equal content.
  defp row_version(entry_uuid) do
    %{rows: [[xmin]]} =
      Repo.query!("SELECT xmin::text FROM phoenix_kit_activities WHERE uuid = $1", [entry_uuid])

    xmin
  end

  test "up stamps 198; down only moves the marker back" do
    entry = entry!("some_webhook_secret")

    run_up()
    assert marker() == "198"

    run_down()
    assert marker() == "197"
    assert withheld?(metadata(entry)), "the withheld values are not restored"
  end
end
