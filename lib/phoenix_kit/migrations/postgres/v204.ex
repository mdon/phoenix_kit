defmodule PhoenixKit.Migrations.Postgres.V204 do
  @moduledoc """
  V204: storage location-truth, the schema half (phase 3 of
  `dev_docs/plans/2026-09-22-storage-libraries.md`).

  From this version on, where a file's bytes are is what its
  `phoenix_kit_file_locations` rows say, not what trying every enabled
  bucket by key finds. Two rules make those rows trustworthy:

    * **One row per instance per bucket (G7).** Duplicate rows are removed,
      keeping the oldest of each `(file_instance_uuid, bucket_uuid)`, and
      `phoenix_kit_file_locations_instance_bucket_index` makes the pair
      unique from now on.
    * **A bucket that still holds files cannot be deleted (G4).** The
      location's bucket FK moves from `ON DELETE CASCADE` (deleting a bucket
      quietly dropped its rows and left its objects behind) to
      `ON DELETE RESTRICT`.

  Nothing that reads bytes runs here. Instances stored before every writer
  recorded its locations (Tessera tiles, comment attachments) are found by
  `Storage.Workers.LocationBackfillJob`, which the application queues on
  boot while any are left, and which probes each bucket once per instance.

  ## Locks

  The dedupe is one `DELETE`. The unique index is a plain build (the chain's
  convention, see V193), so writes to `phoenix_kit_file_locations` wait while
  it builds. The FK is replaced `NOT VALID` → validate → swap, each step its
  own statement (V203's `replace_constraint/7`).

  Re-runnable.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.V203

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc """
  Rolls V204 back: drops the unique index and puts the bucket FK back to
  `ON DELETE CASCADE`. Removed duplicate rows are not restored (they
  described the same object twice).
  """
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)

    List.flatten([
      # The oldest row of each pair stays: by `inserted_at`, then `uuid` to
      # break a tie (two UUIDv7s minted in one millisecond are not ordered).
      """
      DELETE FROM #{p}phoenix_kit_file_locations l
      USING #{p}phoenix_kit_file_locations older
      WHERE l.file_instance_uuid = older.file_instance_uuid
        AND l.bucket_uuid = older.bucket_uuid
        AND (older.inserted_at, older.uuid) < (l.inserted_at, l.uuid)
      """,
      """
      CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_file_locations_instance_bucket_index
      ON #{p}phoenix_kit_file_locations (file_instance_uuid, bucket_uuid)
      """,
      V203.replace_constraint(
        p,
        prefix,
        "phoenix_kit_file_locations",
        "phoenix_kit_file_locations_bucket_id_fkey",
        "FOREIGN KEY (bucket_uuid) REFERENCES #{p}phoenix_kit_buckets(uuid) ON DELETE RESTRICT",
        "c.confdeltype <> 'r'",
        "_v204"
      ),
      "COMMENT ON TABLE #{p}phoenix_kit IS '204'"
    ])
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)

    List.flatten([
      V203.replace_constraint(
        p,
        prefix,
        "phoenix_kit_file_locations",
        "phoenix_kit_file_locations_bucket_id_fkey",
        "FOREIGN KEY (bucket_uuid) REFERENCES #{p}phoenix_kit_buckets(uuid) ON DELETE CASCADE",
        "c.confdeltype <> 'c'",
        "_v204"
      ),
      "DROP INDEX IF EXISTS #{p}phoenix_kit_file_locations_instance_bucket_index",
      "COMMENT ON TABLE #{p}phoenix_kit IS '203'"
    ])
  end
end
