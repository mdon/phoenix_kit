defmodule PhoenixKit.Migrations.Postgres.V111 do
  @moduledoc """
  V111: PDF library tables for the catalogue module.

  Backs the "PDFs" subtab in `phoenix_kit_catalogue`, layered on top
  of core's `phoenix_kit_files` for binary storage / dedup / soft-delete
  / multi-bucket redundancy. Catalogue owns only the per-page text
  index and the user-facing per-upload row.

  ## Tables

  - `phoenix_kit_cat_pdfs` — thin per-upload row. One row per
    "user uploaded this name". `file_uuid` FK → `phoenix_kit_files.uuid`
    `ON DELETE RESTRICT` (catalogue manages the lifecycle; core
    prune can't remove a file referenced by a live catalogue row).
    Two uploads of identical content (different filenames) → two
    `phoenix_kit_cat_pdfs` rows, one shared `phoenix_kit_files` row,
    one shared extraction.
    Soft-delete via `status` sentinel `"active"` / `"trashed"`
    (workspace convention) plus `trashed_at` for trashed-at age UI.

  - `phoenix_kit_cat_pdf_extractions` — keyed by `file_uuid` PK
    (one row per unique PDF content). Holds the worker's state
    machine (`pending → extracting → extracted | scanned_no_text |
    failed`), `page_count`, `extracted_at`, `error_message`.
    Cascades on the file row's hard delete.

  - `phoenix_kit_cat_pdf_page_contents` — content-addressed dedup
    cache. Keyed by `content_hash` (SHA-256 hex of the page's
    normalized text). Same page text across multiple PDFs (boilerplate,
    legal disclaimers, cross-referenced product entries) is stored
    once. The GIN trigram index on `text` lives here, so the search
    index doesn't grow with duplication.

  - `phoenix_kit_cat_pdf_pages` — per-page join. Composite PK
    `(file_uuid, page_number)`. References both the file (cascade on
    file delete) and the page-content cache (restrict; orphaned content
    rows are GC'd by a catalogue-side helper, not by FK cascade, so
    the cache doesn't churn during normal upload/delete cycles).

  Enables `pg_trgm` for the trigram index.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # Drop any pre-existing prototype tables — V111 is the canonical
    # shape; if an earlier (pre-rewrite) V111 left rows behind in dev
    # they get dropped here so the schema matches the new code.
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_cat_pdf_pages CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_cat_pdfs CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_cat_pdf_extractions CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_cat_pdf_page_contents CASCADE")

    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    # ── per-upload row ─────────────────────────────────────────────────

    create table(:phoenix_kit_cat_pdfs, primary_key: false, prefix: prefix) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))

      add(
        :file_uuid,
        references(:phoenix_kit_files,
          column: :uuid,
          type: :uuid,
          on_delete: :restrict,
          prefix: prefix
        ),
        null: false
      )

      add(:original_filename, :string, null: false, size: 500)
      add(:byte_size, :bigint)
      add(:status, :string, null: false, default: "active", size: 20)
      add(:trashed_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(index(:phoenix_kit_cat_pdfs, [:file_uuid], prefix: prefix))
    create(index(:phoenix_kit_cat_pdfs, [:status], prefix: prefix))

    # ── extraction state (one per unique file) ────────────────────────

    create table(:phoenix_kit_cat_pdf_extractions, primary_key: false, prefix: prefix) do
      add(
        :file_uuid,
        references(:phoenix_kit_files,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        primary_key: true,
        null: false
      )

      add(:extraction_status, :string, null: false, default: "pending", size: 20)
      add(:page_count, :integer)
      add(:extracted_at, :utc_datetime)
      add(:error_message, :text)

      timestamps(type: :utc_datetime)
    end

    create(index(:phoenix_kit_cat_pdf_extractions, [:extraction_status], prefix: prefix))

    # ── content-addressed page dedup cache ────────────────────────────

    create table(:phoenix_kit_cat_pdf_page_contents,
             primary_key: false,
             prefix: prefix
           ) do
      add(:content_hash, :string, primary_key: true, null: false, size: 64)
      add(:text, :text, null: false)
      add(:inserted_at, :utc_datetime, null: false)
    end

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_cat_pdf_page_contents_text_trgm_index
    ON #{p}phoenix_kit_cat_pdf_page_contents USING gin (text gin_trgm_ops)
    """)

    # ── per-page join ─────────────────────────────────────────────────

    create table(:phoenix_kit_cat_pdf_pages, primary_key: false, prefix: prefix) do
      add(
        :file_uuid,
        references(:phoenix_kit_files,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        primary_key: true,
        null: false
      )

      add(:page_number, :integer, primary_key: true, null: false)

      add(
        :content_hash,
        references(:phoenix_kit_cat_pdf_page_contents,
          column: :content_hash,
          type: :"varchar(64)",
          on_delete: :restrict,
          prefix: prefix
        ),
        null: false
      )

      add(:inserted_at, :utc_datetime, null: false)
    end

    create(index(:phoenix_kit_cat_pdf_pages, [:content_hash], prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '111'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute(
      "DROP INDEX IF EXISTS #{p}phoenix_kit_cat_pdf_page_contents_text_trgm_index"
    )

    drop_if_exists(table(:phoenix_kit_cat_pdf_pages, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_cat_pdf_page_contents, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_cat_pdf_extractions, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_cat_pdfs, prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '110'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
