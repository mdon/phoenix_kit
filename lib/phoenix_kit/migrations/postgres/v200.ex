defmodule PhoenixKit.Migrations.Postgres.V200 do
  @moduledoc """
  V200: when a photo or video was taken.

  Storage recorded a file's dimensions and duration at ingest but never when
  it was taken — no EXIF date was read, so nothing could order or group a
  library by it. This version adds four columns on `phoenix_kit_files`:

    * `taken_at` (timestamptz) — the moment, UTC
    * `taken_on` (date) — the local calendar date, which is what a library
      groups by
    * `taken_at_offset` (integer) — seconds east of UTC, when known
    * `taken_at_source` (varchar) — `manual`, `exif`, `container`,
      `filename` or `inserted_at`

  and `phoenix_kit_files_capture_date_index` on
  `(user_uuid, taken_on DESC, taken_at DESC)`, partial over the files a media
  library shows: a user's own, visible, processed images and videos. It is
  partial so an edited image's hidden backup and a Tessera tile pyramid —
  thousands of `system_managed` rows per image — cost the index nothing.

  `PhoenixKit.Modules.Storage.CaptureDate` explains the columns.
  `ProcessFileJob` fills them for new uploads and
  `Storage.Workers.CaptureDateBackfillJob` for files stored earlier; nothing
  is backfilled here, because a date comes from a file's bytes, which a
  migration cannot read.

  Additive only; re-runnable.
  """

  use Ecto.Migration

  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V200 back: drops the index and the four columns. Recorded dates are lost."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  # The exact statements `up/1` runs, for the migration test. `prefix` is the
  # bare schema name. The index name stays bare on CREATE (it is created in
  # its table's schema) and is qualified only on DROP.
  def up_statements(prefix) do
    p = prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS taken_at timestamp with time zone",
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS taken_on date",
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS taken_at_offset integer",
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS taken_at_source character varying(255)",
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_files_capture_date_index
      ON #{p}phoenix_kit_files (user_uuid, taken_on DESC, taken_at DESC)
      WHERE system_managed = false
        AND trashed_at IS NULL
        AND parent_file_uuid IS NULL
        AND status = 'active'
        AND file_type IN ('image', 'video')
      """,
      "COMMENT ON TABLE #{p}phoenix_kit IS '200'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = prefix_str(prefix)

    [
      "DROP INDEX IF EXISTS #{p}phoenix_kit_files_capture_date_index",
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS taken_at_source",
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS taken_at_offset",
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS taken_on",
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS taken_at",
      "COMMENT ON TABLE #{p}phoenix_kit IS '199'"
    ]
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
