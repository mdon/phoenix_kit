defmodule PhoenixKit.Migrations.Postgres.V114 do
  @moduledoc """
  V114: Switch integration storage rows to uuid-only keys.

  Before V113, each integration row in `phoenix_kit_settings` had a
  composite key of the shape `integration:<provider>:<name>` (e.g.
  `"integration:google:default"`). That key construction baked the
  human-chosen name into the row's identity, which forced two
  unfortunate constraints:

    * Names had to match a strict regex (`[a-zA-Z0-9][a-zA-Z0-9\\-_]*`)
      because they were path-style segments in the key column.
    * Names had to be unique per provider — the `key` column has a
      unique index, so two `integration:openrouter:work` rows would
      collide at insert time.

  Both restrictions were storage-layout artifacts, not product
  decisions. Operators wanted "My Company Drive" and a second OpenRouter
  account also called "personal" without the system pushing back.

  V114 lifts both by collapsing the storage key to just the row's UUID.
  The `module` column (already set to `"integrations"` for every
  integration row via `@settings_module`) becomes the sole row-class
  discriminator, and `provider` + `name` live purely in `value_json`.

  ## Migration steps

  1. For every row in `phoenix_kit_settings` whose `key` starts with
     `integration:`:

     a. Parse `provider` and `name` from the key (handling the legacy
        V0 shape `integration:google` without a name as
        `provider=google`, `name="default"`).
     b. Ensure `value_json` has `"provider"` and `"name"` populated
        (idempotent — leaves correct values alone).
     c. Ensure `module = 'integrations'` (was already set for
        integrations created via `add_connection/3`, but legacy rows
        pre-`@settings_module` may have it NULL).
     d. Rewrite the `key` column to the row's `uuid`.

  2. Stamp the table comment with `'114'`.

  All work happens in a single transaction (handled by the outer
  migrator). Per-row updates use only the row's `uuid` for routing —
  the new shape is `key = uuid`, so the row's PK is what we touch.

  ## Down migration

  The down path is best-effort: duplicate `(provider, name)` pairs
  cannot be represented in the old shape, so on a name collision we
  suffix `-<8-char-tail>` to keep the rewrite well-defined. The tail
  is taken from UUIDv7's random segment (`substring(uuid::text from
  25 for 8)`), **not** the leading timestamp prefix — multiple rows
  inserted in the same millisecond would otherwise produce identical
  prefixes and collide on the supposedly-unique suffixed key.
  Round-trip `down → up` therefore changes those names by a suffix.
  Acceptable for a one-shot data migration that operators rarely
  roll back.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    rewrite_keys_to_uuid(p)
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '114'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    rewrite_keys_to_composite(p)
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '113'")
  end

  # `up` — rewrite every `integration:%`-keyed row to `key = uuid`.
  #
  # Done in pure SQL via a single CTE so we don't load every row into
  # Elixir memory. The `substring(key from '^integration:([^:]+)')` pulls
  # the provider; the rest of the suffix (or `'default'` when absent) is
  # the name. JSONB merge guarantees we don't clobber an existing
  # `provider`/`name` field — `jsonb_strip_nulls(... || jsonb_build_object(...))`
  # uses concat semantics so the JSONB body wins where it already has a
  # value.
  #
  # The `WHERE` filter is selective: only rows whose `key` literally
  # starts with `integration:` get touched. Already-migrated rows
  # (`key` is a uuid string) silently skip.
  defp rewrite_keys_to_uuid(p) do
    execute("""
    UPDATE #{p}phoenix_kit_settings AS s
       SET key = s.uuid::text,
           module = 'integrations',
           value_json = COALESCE(s.value_json, '{}'::jsonb)
                        || jsonb_build_object(
                             'provider',
                             COALESCE(
                               NULLIF(s.value_json->>'provider', ''),
                               split_part(substring(s.key from 13), ':', 1)
                             ),
                             'name',
                             COALESCE(
                               NULLIF(s.value_json->>'name', ''),
                               NULLIF(split_part(substring(s.key from 13), ':', 2), ''),
                               'default'
                             )
                           )
     WHERE s.key LIKE 'integration:%';
    """)
  end

  # `down` — rewrite back to the composite shape, with `-<8-char-tail>`
  # suffix on name collisions. Single CTE-driven update.
  #
  # The suffix is sourced from `substring(uuid::text from 25 for 8)` —
  # 8 hex chars from the random tail of UUIDv7 (positions 25-32 of the
  # dashed text representation correspond to the post-variant random
  # segment, 32 bits of entropy). The original `from 1 for 8` extracted
  # the **timestamp prefix**, which collides on rows inserted in the
  # same millisecond — and the down path's claim of a "well-defined
  # rewrite" relies on each row landing on a distinct key.
  defp rewrite_keys_to_composite(p) do
    execute("""
    WITH ordered AS (
      SELECT
        s.uuid,
        s.value_json->>'provider' AS provider,
        s.value_json->>'name'     AS name,
        ROW_NUMBER() OVER (
          PARTITION BY s.value_json->>'provider', s.value_json->>'name'
          ORDER BY s.date_added NULLS LAST, s.uuid
        ) AS rn
      FROM #{p}phoenix_kit_settings s
      WHERE s.module = 'integrations'
        AND s.key = s.uuid::text
    )
    UPDATE #{p}phoenix_kit_settings AS s
       SET key = 'integration:' || o.provider || ':' ||
                 CASE
                   WHEN o.rn = 1 THEN o.name
                   ELSE o.name || '-' || substring(s.uuid::text from 25 for 8)
                 END
      FROM ordered o
     WHERE s.uuid = o.uuid;
    """)
  end

  defp prefix_str("public"), do: ""
  defp prefix_str(prefix) when is_binary(prefix), do: "#{prefix}."
end
