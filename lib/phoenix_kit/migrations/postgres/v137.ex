defmodule PhoenixKit.Migrations.Postgres.V137 do
  @moduledoc """
  V137: Email event deduplication indexes + `aws_message_id` backfill, plus
  optional performance indexes for the emails module (`phoenix_kit_emails`).

  ## Event dedup

  The `PhoenixKit.Modules.Emails.Event` schema declares unique constraints that
  the database never enforced (a schema↔DB mismatch). This adds the two partial
  unique indexes that back them, deduping at the DB level — at-least-once SQS
  delivery and racing pollers could previously insert duplicate events:

    - **single-occurrence** types (delivery / bounce / complaint / send / reject /
      delivery_delay / subscription / rendering_failure / queued): one row per
      `(email_log_uuid, event_type)`.
    - **multi-occurrence** types (open / click): one row per
      `(email_log_uuid, event_type, occurred_at)`, so a recipient's repeated
      opens and distinct link clicks are kept while an exact SQS redelivery
      (identical timestamp) is collapsed.

  Pre-existing duplicates are removed first so the unique indexes can be created.
  `phoenix_kit_email_events` has no bigint `id` (dropped in V74); `uuid` is the
  UUIDv7 primary key and is time-ordered, so `MIN(uuid)` per group is the earliest
  row — it is kept, the rest deleted.

  `email_log_uuid` is the canonical FK (NOT NULL, backfilled and FK-constrained in
  V56/V70; the legacy bigint `email_log_id` was dropped in V74).

  ## aws_message_id backfill

  The hot SQS lookup now relies solely on the dedicated indexed `aws_message_id`
  column (the legacy headers-JSONB scan was removed in the app code). Backfill it
  for any legacy rows whose AWS MessageId lives only in the `headers` JSONB.
  `DISTINCT ON (aws_id)` + a `NOT EXISTS` guard keep it safe against the existing
  partial unique index on `aws_message_id`.

  ## Optional performance indexes

  pg_trgm substring-search indexes for the admin email list (`pg_trgm` is enabled
  from V111), per-template open/click analytics composites, and a partial index
  for the archiver's body-compression scan.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # --- Event dedup: remove pre-existing duplicates, then add the unique indexes

    # single-occurrence types: keep the earliest (smallest UUIDv7) per pair
    execute("""
    DELETE FROM #{p}phoenix_kit_email_events e
    USING #{p}phoenix_kit_email_events d
    WHERE e.email_log_uuid = d.email_log_uuid
      AND e.event_type = d.event_type
      AND e.event_type NOT IN ('open', 'click')
      AND e.uuid > d.uuid
    """)

    # multi-occurrence types (open/click): dedup on (uuid, type, occurred_at)
    execute("""
    DELETE FROM #{p}phoenix_kit_email_events e
    USING #{p}phoenix_kit_email_events d
    WHERE e.email_log_uuid = d.email_log_uuid
      AND e.event_type = d.event_type
      AND e.occurred_at = d.occurred_at
      AND e.event_type IN ('open', 'click')
      AND e.uuid > d.uuid
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_events_log_uuid_event_type_index
    ON #{p}phoenix_kit_email_events (email_log_uuid, event_type)
    WHERE event_type NOT IN ('open', 'click')
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_events_log_uuid_type_occurred_index
    ON #{p}phoenix_kit_email_events (email_log_uuid, event_type, occurred_at)
    WHERE event_type IN ('open', 'click')
    """)

    # --- aws_message_id backfill from legacy headers JSONB (conflict-safe)
    execute("""
    UPDATE #{p}phoenix_kit_email_logs l
    SET aws_message_id = src.aws_id
    FROM (
      SELECT DISTINCT ON (aws_id) uuid, aws_id
      FROM (
        SELECT uuid,
               COALESCE(headers->>'aws_message_id',
                        headers->>'X-AWS-Message-Id',
                        headers->>'MessageId') AS aws_id
        FROM #{p}phoenix_kit_email_logs
        WHERE aws_message_id IS NULL
      ) candidates
      WHERE aws_id IS NOT NULL
      ORDER BY aws_id, uuid
    ) src
    WHERE l.uuid = src.uuid
      AND NOT EXISTS (
        SELECT 1 FROM #{p}phoenix_kit_email_logs x
        WHERE x.aws_message_id = src.aws_id
      )
    """)

    # --- Optional performance indexes

    # pg_trgm substring search for the admin email list ("to" is a reserved word)
    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_to_trgm_index
    ON #{p}phoenix_kit_email_logs USING gin ("to" gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_subject_trgm_index
    ON #{p}phoenix_kit_email_logs USING gin (subject gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_campaign_id_trgm_index
    ON #{p}phoenix_kit_email_logs USING gin (campaign_id gin_trgm_ops)
    """)

    # Per-template open/click analytics (get_template_stats CASE WHEN ... IS NOT NULL)
    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_template_opened_index
    ON #{p}phoenix_kit_email_logs (template_name, opened_at)
    WHERE opened_at IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_template_clicked_index
    ON #{p}phoenix_kit_email_logs (template_name, clicked_at)
    WHERE clicked_at IS NOT NULL
    """)

    # Archiver body-compression scan (compress_old_bodies streams sent_at order
    # over rows with a body to compress)
    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_compress_scan_index
    ON #{p}phoenix_kit_email_logs (sent_at)
    WHERE body_full IS NOT NULL
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '137'")
  end

  @doc """
  Drops the V137 indexes. The `aws_message_id` backfill is data-only and harmless
  to keep, so it is not reversed.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_email_logs_compress_scan_index")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_email_logs_template_clicked_index")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_email_logs_template_opened_index")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_email_logs_campaign_id_trgm_index")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_email_logs_subject_trgm_index")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_email_logs_to_trgm_index")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_email_events_log_uuid_type_occurred_index")
    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_email_events_log_uuid_event_type_index")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '136'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
