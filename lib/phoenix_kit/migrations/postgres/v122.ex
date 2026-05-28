defmodule PhoenixKit.Migrations.Postgres.V122 do
  @moduledoc """
  V122: Create `phoenix_kit_location_spaces` — the nested-space (room /
  floor / zone / etc.) breakdown under a `phoenix_kit_locations` row.

  Each row belongs to exactly one Location (required FK, cascade) and
  may optionally belong to a parent Space within the same Location
  (self-ref FK, cascade) forming a filesystem-like tree of arbitrary
  depth.

  The cross-row "child belongs to same location as parent" guarantee
  is enforced at application layer in `PhoenixKitLocations.Spaces` —
  enforcing it at the DB requires a composite FK + redundant column
  pair which is heavier than the consumer surface justifies.

  `data JSONB` mirrors the parent Location's column: top-level keys
  carry attachment pointers (`files_folder_uuid`, `featured_image_uuid`)
  and the multilang translation tree (`%{ "es-ES" => %{ "name" =>
  "..."} }`). Primary-language values stay denormalized in the
  dedicated `name` / `description` columns for cheap querying.
  """

  use Ecto.Migration

  @kinds ~w(floor room hall suite section zone aisle shelf corner)

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    create_if_not_exists table(:phoenix_kit_location_spaces,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))

      add(
        :location_uuid,
        references(:phoenix_kit_locations,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(
        :parent_uuid,
        references(:phoenix_kit_location_spaces,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        )
      )

      add(:kind, :string, null: false, size: 32)
      add(:name, :string, null: false, size: 255)
      add(:description, :text)
      add(:notes, :text)
      add(:status, :string, null: false, default: "active", size: 20)
      add(:position, :integer, null: false, default: 0)
      add(:data, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(
      index(:phoenix_kit_location_spaces, [:location_uuid], prefix: prefix)
    )

    create_if_not_exists(
      index(:phoenix_kit_location_spaces, [:parent_uuid], prefix: prefix)
    )

    # Sibling-ordering query: list spaces under (location, parent) by position.
    create_if_not_exists(
      index(:phoenix_kit_location_spaces, [:location_uuid, :parent_uuid, :position],
        prefix: prefix
      )
    )

    # Kind whitelist mirrors the schema's @kinds module attribute. Keep in
    # sync if the consumer adds a new label. DROP-then-ADD pattern (same
    # shape as V121) so the migration stays idempotent on re-run.
    execute(
      "ALTER TABLE #{p}phoenix_kit_location_spaces DROP CONSTRAINT IF EXISTS phoenix_kit_location_spaces_kind_check"
    )

    execute("""
    ALTER TABLE #{p}phoenix_kit_location_spaces
      ADD CONSTRAINT phoenix_kit_location_spaces_kind_check
      CHECK (kind IN (#{Enum.map_join(@kinds, ", ", &"'#{&1}'")}))
    """)

    execute(
      "ALTER TABLE #{p}phoenix_kit_location_spaces DROP CONSTRAINT IF EXISTS phoenix_kit_location_spaces_status_check"
    )

    execute("""
    ALTER TABLE #{p}phoenix_kit_location_spaces
      ADD CONSTRAINT phoenix_kit_location_spaces_status_check
      CHECK (status IN ('active', 'inactive'))
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '122'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(table(:phoenix_kit_location_spaces, prefix: prefix))
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '121'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
