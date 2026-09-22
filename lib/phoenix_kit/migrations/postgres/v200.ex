defmodule PhoenixKit.Migrations.Postgres.V200 do
  @moduledoc """
  V200: A user's view preferences, per view.

  `phoenix_kit_user_view_prefs` holds what one admin chose for one view — a
  table's columns and their order, and whatever else the view's owner keeps
  there (a sort, filters) — one row per `(user_uuid, key)`. `key` names the
  view (`"users"`, `"catalogue.detail_items"`); `prefs` is a JSON object of
  top-level fields, each written whole.

  Until now the Users table and the website-access table kept ONE column
  list for the whole site in a setting, the catalogue kept its per-user
  choices inside `phoenix_kit_users.custom_fields` (written as a whole map
  from whatever copy of the user the page held), and CRM kept them in a
  table of its own. A row per view is written without touching the user's
  row, and a field is patched with `prefs || new` in the upsert itself, so
  two tabs changing different fields both keep their change.

  `PhoenixKit.Users.ViewPrefs` is the read and write path. The FK is
  `ON DELETE CASCADE`: deleting a user takes their preferences with them.
  The unique index is the upsert's conflict target and, leading with
  `user_uuid`, also serves the FK.

  Additive only; re-runnable.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    create_if_not_exists table(:phoenix_kit_user_view_prefs,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment(Helpers.uuid_v7_call(prefix)))

      add(
        :user_uuid,
        references(:phoenix_kit_users,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(:key, :string, size: 255, null: false)
      add(:prefs, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    # Index name stays bare on CREATE — it is qualified only on DROP (see
    # dev_docs/guides/2026-07-27-prefix-safe-migrations.md).
    create_if_not_exists(
      unique_index(:phoenix_kit_user_view_prefs, [:user_uuid, :key],
        prefix: prefix,
        name: "phoenix_kit_user_view_prefs_user_key_index"
      )
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '200'")
  end

  @doc "Rolls V200 back: drops the table. Every saved view preference is lost."
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(table(:phoenix_kit_user_view_prefs, prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '199'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
