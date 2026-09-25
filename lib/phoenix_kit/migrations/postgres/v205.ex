defmodule PhoenixKit.Migrations.Postgres.V205 do
  @moduledoc """
  V205: storage profiles and variant sets, the schema half (phase 4 of
  `dev_docs/plans/2026-09-22-storage-libraries.md`).

  A library says *where* its bytes live by pointing at a **storage profile**,
  and *which* derived files it gets by pointing at a **variant set**. Both
  default to NULL, which means the Default one, so nothing changes for an
  existing install:

    * `phoenix_kit_storage_profiles` — `copies_originals`, `copies_variants`,
      `min_copies_on_write` and a `revision` bumped on every change. One row
      is seeded: **Default**, under the fixed uuid
      `00000000-0000-7000-8000-000000000002`, with both copy counts taken from
      `storage_redundancy_copies`.
    * `phoenix_kit_storage_profile_buckets` — the profile's buckets, each with
      a `role` (`primary` | `replica` | `backup`), what it `stores` (`all` |
      `originals` | `derived`), a fixed `write_priority` (NULL = the shuffled
      pool), a `serve_order` and a `status` (`active` | `read_only` |
      `draining`). `storage_class` and `encryption` are reserved. Every
      bucket joins Default: `write_priority` is its `priority` (0 becomes the
      pool) and `serve_order` is today's read order, local buckets first and
      then by priority. A bucket a profile uses cannot be deleted.
    * `phoenix_kit_variant_sets` — `generate_variants` and `generate_tiles`
      (seeded from `storage_auto_generate_variants` and
      `storage_tile_generation_enabled`), `selectable` (user libraries may
      pick it) and a `revision`. One row is seeded: **Default**, under
      `00000000-0000-7000-8000-000000000003`.
    * `variant_set_uuid` on `phoenix_kit_storage_dimensions`: NOT NULL,
      `ON DELETE CASCADE`, with the Default set's uuid as its column
      DEFAULT, so every existing size is in Default and a writer that names
      no set keeps working. Size names are unique per set instead of site-wide
      (`phoenix_kit_storage_dimensions_name_index` gains a leading
      `variant_set_uuid`).
    * `storage_profile_uuid` / `variant_set_uuid` on libraries (NULL = the
      Default, `ON DELETE RESTRICT`).
    * What a file was placed by: `placed_profile_uuid` / `placed_revision`
      and `placed_variant_set_uuid` / `placed_variant_revision` on files.
      **NULL means the Default at revision 1**, which is what every existing
      file is, so no file row is rewritten. A file is stale, and the
      reconciler moves or regenerates it, when what it was placed by differs
      from its library's. The files that are under-replicated today are
      marked stale here (`placed_revision = 0`): the ones whose completed
      instances do not each have as many active locations on enabled
      buckets as the Default wants (or as there are enabled buckets, if
      fewer).
    * `spec_hash` on file instances: which spec of a size produced the
      instance. Stamped here on every instance whose name is a size of the
      Default set (or one of its alternative formats), with that size's
      current spec (`PhoenixKit.Modules.Storage.VariantSets.spec_hash/2`
      computes the same value). Instances not made from a size (the
      original, an annotated thumbnail, a burned render) have none.

  Nothing is copied, moved or regenerated here.

  ## Locks

  New tables and nullable columns without defaults are metadata-only. The
  dimensions column has a constant default (metadata-only) and becomes NOT
  NULL through a validated check (the V164 pattern). The `spec_hash` stamp is
  one `UPDATE` over the instances named like a size. The name index is a
  plain rebuild on a table of a few rows.

  Re-runnable.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKit.Migrations.Postgres.V203

  @default_profile_uuid "00000000-0000-7000-8000-000000000002"
  @default_variant_set_uuid "00000000-0000-7000-8000-000000000003"

  @doc false
  def default_profile_uuid, do: @default_profile_uuid

  @doc false
  def default_variant_set_uuid, do: @default_variant_set_uuid

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc """
  Rolls V205 back. Sizes of any set other than Default are deleted (size
  names become unique site-wide again), then the tables and columns go.
  """
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)

    List.flatten([
      tables(p, prefix),
      seeds(p),
      library_columns(p, prefix),
      """
      ALTER TABLE #{p}phoenix_kit_files
        ADD COLUMN IF NOT EXISTS placed_profile_uuid uuid,
        ADD COLUMN IF NOT EXISTS placed_revision integer,
        ADD COLUMN IF NOT EXISTS placed_variant_set_uuid uuid,
        ADD COLUMN IF NOT EXISTS placed_variant_revision integer
      """,
      "ALTER TABLE #{p}phoenix_kit_file_instances ADD COLUMN IF NOT EXISTS spec_hash character varying(32)",
      dimension_columns(p, prefix),
      stamps(p),
      "COMMENT ON TABLE #{p}phoenix_kit IS '205'"
    ])
  end

  defp tables(p, prefix) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_storage_profiles (
        uuid uuid DEFAULT #{Helpers.uuid_v7_call(prefix)} NOT NULL,
        name character varying(255) NOT NULL,
        is_default boolean DEFAULT false NOT NULL,
        copies_originals integer DEFAULT 1 NOT NULL,
        copies_variants integer DEFAULT 1 NOT NULL,
        min_copies_on_write integer DEFAULT 1 NOT NULL,
        revision integer DEFAULT 1 NOT NULL,
        inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_storage_profiles_pkey PRIMARY KEY (uuid),
        CONSTRAINT phoenix_kit_storage_profiles_copies_check CHECK (
          copies_originals BETWEEN 1 AND 5
          AND copies_variants BETWEEN 1 AND 5
          AND min_copies_on_write BETWEEN 1 AND copies_originals
        )
      )
      """,
      """
      CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_storage_profiles_name_index
      ON #{p}phoenix_kit_storage_profiles (lower(name))
      """,
      """
      CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_storage_profiles_default_index
      ON #{p}phoenix_kit_storage_profiles (is_default)
      WHERE is_default
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_storage_profile_buckets (
        profile_uuid uuid NOT NULL,
        bucket_uuid uuid NOT NULL,
        role character varying(20) DEFAULT 'primary' NOT NULL,
        stores character varying(20) DEFAULT 'all' NOT NULL,
        write_priority integer,
        serve_order integer DEFAULT 0 NOT NULL,
        status character varying(20) DEFAULT 'active' NOT NULL,
        storage_class character varying(64),
        encryption jsonb,
        inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_storage_profile_buckets_pkey PRIMARY KEY (profile_uuid, bucket_uuid),
        CONSTRAINT phoenix_kit_storage_profile_buckets_profile_fkey FOREIGN KEY (profile_uuid)
          REFERENCES #{p}phoenix_kit_storage_profiles(uuid) ON DELETE CASCADE,
        CONSTRAINT phoenix_kit_storage_profile_buckets_bucket_fkey FOREIGN KEY (bucket_uuid)
          REFERENCES #{p}phoenix_kit_buckets(uuid) ON DELETE RESTRICT,
        CONSTRAINT phoenix_kit_storage_profile_buckets_role_check
          CHECK (role IN ('primary', 'replica', 'backup')),
        CONSTRAINT phoenix_kit_storage_profile_buckets_stores_check
          CHECK (stores IN ('all', 'originals', 'derived')),
        CONSTRAINT phoenix_kit_storage_profile_buckets_status_check
          CHECK (status IN ('active', 'read_only', 'draining'))
      )
      """,
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_storage_profile_buckets_bucket_uuid_index
      ON #{p}phoenix_kit_storage_profile_buckets (bucket_uuid)
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_variant_sets (
        uuid uuid DEFAULT #{Helpers.uuid_v7_call(prefix)} NOT NULL,
        name character varying(255) NOT NULL,
        is_default boolean DEFAULT false NOT NULL,
        selectable boolean DEFAULT false NOT NULL,
        generate_variants boolean DEFAULT true NOT NULL,
        generate_tiles boolean DEFAULT false NOT NULL,
        revision integer DEFAULT 1 NOT NULL,
        inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_variant_sets_pkey PRIMARY KEY (uuid)
      )
      """,
      """
      CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_variant_sets_name_index
      ON #{p}phoenix_kit_variant_sets (lower(name))
      """,
      """
      CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_variant_sets_default_index
      ON #{p}phoenix_kit_variant_sets (is_default)
      WHERE is_default
      """
    ]
  end

  # The two defaults, from today's global settings. The Default profile gets
  # its buckets only while it has none, so a re-run does not put back a
  # bucket an admin has taken out.
  defp seeds(p) do
    [
      """
      INSERT INTO #{p}phoenix_kit_storage_profiles
        (uuid, name, is_default, copies_originals, copies_variants, min_copies_on_write,
         revision, inserted_at, updated_at)
      SELECT '#{@default_profile_uuid}', 'Default', true, c.copies, c.copies, 1, 1, NOW(), NOW()
      FROM (
        SELECT LEAST(GREATEST(COALESCE(
          (SELECT CASE WHEN value ~ '^[0-9]+$' THEN value::integer END
           FROM #{p}phoenix_kit_settings WHERE key = 'storage_redundancy_copies'),
          1), 1), 5) AS copies
      ) c
      ON CONFLICT (uuid) DO NOTHING
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM #{p}phoenix_kit_storage_profile_buckets
          WHERE profile_uuid = '#{@default_profile_uuid}'
        ) THEN
          INSERT INTO #{p}phoenix_kit_storage_profile_buckets
            (profile_uuid, bucket_uuid, role, stores, write_priority, serve_order, status,
             inserted_at, updated_at)
          SELECT '#{@default_profile_uuid}', b.uuid, 'primary', 'all', NULLIF(b.priority, 0),
                 row_number() OVER (
                   ORDER BY (b.provider = 'local') DESC, b.priority, b.inserted_at, b.uuid
                 ),
                 'active', NOW(), NOW()
          FROM #{p}phoenix_kit_buckets b
          ON CONFLICT (profile_uuid, bucket_uuid) DO NOTHING;
        END IF;
      END
      $$
      """,
      """
      INSERT INTO #{p}phoenix_kit_variant_sets
        (uuid, name, is_default, selectable, generate_variants, generate_tiles, revision,
         inserted_at, updated_at)
      VALUES (
        '#{@default_variant_set_uuid}', 'Default', true, true,
        COALESCE((SELECT value FROM #{p}phoenix_kit_settings
                  WHERE key = 'storage_auto_generate_variants'), 'true') = 'true',
        COALESCE((SELECT value FROM #{p}phoenix_kit_settings
                  WHERE key = 'storage_tile_generation_enabled'), 'false') = 'true',
        1, NOW(), NOW()
      )
      ON CONFLICT (uuid) DO NOTHING
      """
    ]
  end

  defp library_columns(p, prefix) do
    table = "phoenix_kit_storage_libraries"

    [
      """
      ALTER TABLE #{p}#{table}
        ADD COLUMN IF NOT EXISTS storage_profile_uuid uuid,
        ADD COLUMN IF NOT EXISTS variant_set_uuid uuid
      """,
      add_constraint(
        p,
        prefix,
        table,
        "phoenix_kit_storage_libraries_profile_fkey",
        "FOREIGN KEY (storage_profile_uuid) REFERENCES #{p}phoenix_kit_storage_profiles(uuid) ON DELETE RESTRICT"
      ),
      "ALTER TABLE #{p}#{table} VALIDATE CONSTRAINT phoenix_kit_storage_libraries_profile_fkey",
      add_constraint(
        p,
        prefix,
        table,
        "phoenix_kit_storage_libraries_variant_set_fkey",
        "FOREIGN KEY (variant_set_uuid) REFERENCES #{p}phoenix_kit_variant_sets(uuid) ON DELETE RESTRICT"
      ),
      "ALTER TABLE #{p}#{table} VALIDATE CONSTRAINT phoenix_kit_storage_libraries_variant_set_fkey"
    ]
  end

  defp dimension_columns(p, prefix) do
    table = "phoenix_kit_storage_dimensions"
    check = "#{table}_variant_set_not_null"

    [
      "ALTER TABLE #{p}#{table} ADD COLUMN IF NOT EXISTS variant_set_uuid uuid DEFAULT '#{@default_variant_set_uuid}'::uuid",
      add_constraint(p, prefix, table, check, "CHECK (variant_set_uuid IS NOT NULL)"),
      "ALTER TABLE #{p}#{table} VALIDATE CONSTRAINT #{check}",
      "ALTER TABLE #{p}#{table} ALTER COLUMN variant_set_uuid SET NOT NULL",
      "ALTER TABLE #{p}#{table} DROP CONSTRAINT IF EXISTS #{check}",
      add_constraint(
        p,
        prefix,
        table,
        "phoenix_kit_storage_dimensions_variant_set_fkey",
        "FOREIGN KEY (variant_set_uuid) REFERENCES #{p}phoenix_kit_variant_sets(uuid) ON DELETE CASCADE"
      ),
      "ALTER TABLE #{p}#{table} VALIDATE CONSTRAINT phoenix_kit_storage_dimensions_variant_set_fkey",
      # Size names: unique per set instead of site-wide (G18). Rebuilt only
      # while the index still has the old shape.
      """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_indexes
          WHERE schemaname = '#{prefix}'
            AND indexname = 'phoenix_kit_storage_dimensions_name_index'
            AND indexdef NOT LIKE '%variant_set_uuid%'
        ) THEN
          DROP INDEX #{p}phoenix_kit_storage_dimensions_name_index;
        END IF;
      END
      $$
      """,
      """
      CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_storage_dimensions_name_index
      ON #{p}phoenix_kit_storage_dimensions (variant_set_uuid, name)
      """
    ]
  end

  @doc false
  # The SQL for a size's spec hash, over the row `d` with the output format
  # `format_sql`. `VariantSets.spec_hash/2` builds the same text.
  def spec_hash_sql(format_sql) do
    """
    md5(
      'v1|w=' || COALESCE(d.width::text, '')
      || '|h=' || COALESCE(d.height::text, '')
      || '|q=' || COALESCE(d.quality::text, '')
      || '|f=' || COALESCE(#{format_sql}, '')
      || '|a=' || CASE WHEN d.maintain_aspect_ratio THEN 't' ELSE 'f' END
    )
    """
  end

  defp stamps(p) do
    [
      # An instance named like a size was made from that size's spec.
      """
      UPDATE #{p}phoenix_kit_file_instances fi
      SET spec_hash = #{spec_hash_sql("d.format")}
      FROM #{p}phoenix_kit_storage_dimensions d
      WHERE fi.spec_hash IS NULL
        AND d.variant_set_uuid = '#{@default_variant_set_uuid}'
        AND d.name <> 'original'
        AND fi.variant_name = d.name
      """,
      # An alternative format of a size: `<name>_<format>`.
      """
      UPDATE #{p}phoenix_kit_file_instances fi
      SET spec_hash = #{spec_hash_sql("alt.format")}
      FROM #{p}phoenix_kit_storage_dimensions d
      CROSS JOIN LATERAL unnest(d.alternative_formats) AS alt(format)
      WHERE fi.spec_hash IS NULL
        AND d.variant_set_uuid = '#{@default_variant_set_uuid}'
        AND d.name <> 'original'
        AND fi.variant_name = d.name || '_' || alt.format
      """,
      # Under-replicated files are stale from the start. The target is the
      # Default's copy count, or the number of enabled buckets if fewer.
      """
      UPDATE #{p}phoenix_kit_files f
      SET placed_profile_uuid = '#{@default_profile_uuid}', placed_revision = 0
      FROM (
        SELECT LEAST(
          (SELECT copies_originals FROM #{p}phoenix_kit_storage_profiles
           WHERE uuid = '#{@default_profile_uuid}'),
          (SELECT count(*) FROM #{p}phoenix_kit_buckets WHERE enabled)
        ) AS copies
      ) target
      WHERE f.placed_profile_uuid IS NULL
        AND EXISTS (
          SELECT 1
          FROM #{p}phoenix_kit_file_instances fi
          WHERE fi.file_uuid = f.uuid
            AND fi.processing_status = 'completed'
            AND (
              SELECT count(*)
              FROM #{p}phoenix_kit_file_locations l
              JOIN #{p}phoenix_kit_buckets b ON b.uuid = l.bucket_uuid AND b.enabled
              WHERE l.file_instance_uuid = fi.uuid AND l.status = 'active'
            ) < target.copies
        )
      """
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)

    List.flatten([
      "DELETE FROM #{p}phoenix_kit_storage_dimensions WHERE variant_set_uuid <> '#{@default_variant_set_uuid}'",
      """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM pg_indexes
          WHERE schemaname = '#{prefix}'
            AND indexname = 'phoenix_kit_storage_dimensions_name_index'
            AND indexdef LIKE '%variant_set_uuid%'
        ) THEN
          DROP INDEX #{p}phoenix_kit_storage_dimensions_name_index;
        END IF;
      END
      $$
      """,
      "ALTER TABLE #{p}phoenix_kit_storage_dimensions DROP COLUMN IF EXISTS variant_set_uuid",
      """
      CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_storage_dimensions_name_index
      ON #{p}phoenix_kit_storage_dimensions (name)
      """,
      "ALTER TABLE #{p}phoenix_kit_file_instances DROP COLUMN IF EXISTS spec_hash",
      """
      ALTER TABLE #{p}phoenix_kit_files
        DROP COLUMN IF EXISTS placed_profile_uuid,
        DROP COLUMN IF EXISTS placed_revision,
        DROP COLUMN IF EXISTS placed_variant_set_uuid,
        DROP COLUMN IF EXISTS placed_variant_revision
      """,
      """
      ALTER TABLE #{p}phoenix_kit_storage_libraries
        DROP COLUMN IF EXISTS storage_profile_uuid,
        DROP COLUMN IF EXISTS variant_set_uuid
      """,
      "DROP TABLE IF EXISTS #{p}phoenix_kit_variant_sets",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_storage_profile_buckets",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_storage_profiles",
      "COMMENT ON TABLE #{p}phoenix_kit IS '204'"
    ])
  end

  # Adds a constraint `NOT VALID` unless the table already has one of that
  # name (checked through pg_class + pg_namespace, never `::regclass`).
  defp add_constraint(p, prefix, table, name, definition) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{p}#{table} ADD CONSTRAINT #{name} #{definition} NOT VALID;
      END IF;
    END
    $$
    """
  end
end
