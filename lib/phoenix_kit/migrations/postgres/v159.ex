defmodule PhoenixKit.Migrations.Postgres.V159 do
  @moduledoc """
  V159: Publishing categories + post view counters
  (`phoenix_kit_publishing` module).

  ## phoenix_kit_publishing_categories

  Hierarchical, per-group taxonomy (WordPress-parity categories). The tree
  is a nullable `parent_uuid` self-FK — same shape as V103's catalogue
  categories; cycle/scope rules are context-layer responsibilities. `slug`
  is unique per group (not globally — two groups can both have "news").
  `name_i18n` carries per-language display names keyed by language code,
  mirroring the group-name convention in the groups table's `data` JSONB.

  Deleting a group cascades its categories; deleting a parent lifts its
  children to the root (`ON DELETE SET NULL`) rather than orphaning a
  subtree.

  ## phoenix_kit_publishing_post_categories

  Post↔category assignment (M:N — WordPress semantics: taxonomy is
  post-level, not per-version). Both sides cascade.

  ## phoenix_kit_publishing_post_views

  Per-day view rollups: one `(post_uuid, view_date)` row incremented in
  place. Totals are `SUM(count)`; time-series come free. Deduplication /
  bot filtering happen app-side before the increment — the table stores
  accepted counts only, no per-request rows and no reader PII.

  All operations are idempotent.
  """

  use Ecto.Migration

  @disable_ddl_transaction true

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_publishing_categories (
      uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
      group_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_publishing_groups(uuid) ON DELETE CASCADE,
      parent_uuid UUID REFERENCES #{p}phoenix_kit_publishing_categories(uuid) ON DELETE SET NULL,
      name VARCHAR(255) NOT NULL,
      slug VARCHAR(255) NOT NULL,
      name_i18n JSONB NOT NULL DEFAULT '{}',
      description VARCHAR(1024),
      position INTEGER NOT NULL DEFAULT 0,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT phoenix_kit_publishing_categories_group_slug_uniq UNIQUE (group_uuid, slug)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_categories_group
    ON #{p}phoenix_kit_publishing_categories (group_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_categories_parent
    ON #{p}phoenix_kit_publishing_categories (parent_uuid)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_publishing_post_categories (
      post_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_publishing_posts(uuid) ON DELETE CASCADE,
      category_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_publishing_categories(uuid) ON DELETE CASCADE,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (post_uuid, category_uuid)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_publishing_post_categories_category
    ON #{p}phoenix_kit_publishing_post_categories (category_uuid)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_publishing_post_views (
      post_uuid UUID NOT NULL REFERENCES #{p}phoenix_kit_publishing_posts(uuid) ON DELETE CASCADE,
      view_date DATE NOT NULL,
      count INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (post_uuid, view_date)
    )
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '159'")
  end

  @doc """
  Rolls V159 back by dropping the categories, assignment, and view tables.

  **Lossy rollback:** all categories, assignments, and view counts are
  lost. Back up before rolling back in production.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_publishing_post_views CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_publishing_post_categories CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_publishing_categories CASCADE")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '158'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
