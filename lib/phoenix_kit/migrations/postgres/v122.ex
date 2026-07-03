defmodule PhoenixKit.Migrations.Postgres.V122 do
  @moduledoc """
  V122: Three unrelated additions bundled together because they shipped
  in the same release cycle.

  ## 1. `phoenix_kit_location_spaces` — nested floors / rooms / zones
  under a `phoenix_kit_locations` row

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

  ## 2. `translations JSONB` on the three staff tables

  Adds `translations JSONB NOT NULL DEFAULT '{}'` to
  `phoenix_kit_staff_departments`, `phoenix_kit_staff_teams`, and
  `phoenix_kit_staff_people`. Mirrors the settings-translations shape
  already used by `phoenix_kit_projects` V112 (project / project_task /
  project_assignment): primary stays in dedicated columns, the JSONB
  holds non-primary overrides only.

      %{"es-ES" => %{"name" => "...", "description" => "..."}}

  Translatable fields by schema:

    * Department: `name`, `description`
    * Team: `name`, `description`
    * Person: `job_title`, `bio`, `skills`, `notes`

  Read paths use `<Schema>.localized_<field>/2` helpers with primary-
  fallback semantics.

  ## 3. `name` column on `phoenix_kit_staff_people`

  Adds a single nullable `name VARCHAR` for the staff person's full
  display name — consistent with Department, Team, Space, and Location
  which all use a single `name` field. Owned by the staff profile
  rather than `phoenix_kit_users` because placeholder users created via
  `Staff.find_or_create_user_by_email/1` are anonymous until claimed.
  """

  use Ecto.Migration

  @kinds ~w(floor room hall suite section zone aisle shelf corner)

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # ── Backfill `phoenix_kit_locations` parent (issue #598) ────────
    # `phoenix_kit_location_spaces` below carries a required FK to
    # `phoenix_kit_locations`, which is created only in V91. Because the
    # locations tables were added to an already-released `v91.ex`, any
    # database that passed V91 *before* that addition never received the
    # parent table — so V122 would abort with `42P01 undefined_table`
    # while building the FK. Recreate it here (mirroring V91's final
    # shape) so the FK target always exists. Idempotent no-op on installs
    # where V91 already created it.
    create_if_not_exists table(:phoenix_kit_locations,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
      add(:name, :string, null: false, size: 255)
      add(:description, :text)
      add(:public_notes, :text)

      add(:address_line_1, :string, size: 500)
      add(:address_line_2, :string, size: 500)
      add(:city, :string, size: 255)
      add(:state, :string, size: 255)
      add(:postal_code, :string, size: 20)
      add(:country, :string, size: 255)

      add(:phone, :string, size: 50)
      add(:email, :string, size: 255)
      add(:website, :string, size: 500)

      add(:notes, :text)
      add(:status, :string, default: "active", size: 20)

      add(:features, :map, default: %{})
      add(:data, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_locations, [:status], prefix: prefix))

    create_if_not_exists table(:phoenix_kit_location_spaces,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))

      add(
        :location_uuid,
        references(:phoenix_kit_locations,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(
        :parent_uuid,
        references(:phoenix_kit_location_spaces,
          column: :uuid,
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

    create_if_not_exists(index(:phoenix_kit_location_spaces, [:location_uuid], prefix: prefix))

    create_if_not_exists(index(:phoenix_kit_location_spaces, [:parent_uuid], prefix: prefix))

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

    # ── Staff translations columns ──────────────────────────────────
    # ALTER TABLE ... ADD COLUMN IF NOT EXISTS — safe to re-run on a
    # database that's already at V122 but missing the staff translation
    # bits (the case for installs that picked up the early V122 before
    # this bundling).
    execute(
      "ALTER TABLE #{p}phoenix_kit_staff_departments ADD COLUMN IF NOT EXISTS translations JSONB NOT NULL DEFAULT '{}'::jsonb"
    )

    execute(
      "ALTER TABLE #{p}phoenix_kit_staff_teams ADD COLUMN IF NOT EXISTS translations JSONB NOT NULL DEFAULT '{}'::jsonb"
    )

    execute(
      "ALTER TABLE #{p}phoenix_kit_staff_people ADD COLUMN IF NOT EXISTS translations JSONB NOT NULL DEFAULT '{}'::jsonb"
    )

    # ── Person.name ─────────────────────────────────────────────────
    execute("ALTER TABLE #{p}phoenix_kit_staff_people ADD COLUMN IF NOT EXISTS name VARCHAR")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '122'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("ALTER TABLE #{p}phoenix_kit_staff_people DROP COLUMN IF EXISTS name")

    # Earlier V123 sketch added first / middle / last as three separate
    # columns before we simplified to a single `name`. Drop them too so
    # the rollback fully reverses any V122 shape that might already have
    # been applied to this host.
    execute("ALTER TABLE #{p}phoenix_kit_staff_people DROP COLUMN IF EXISTS first_name")
    execute("ALTER TABLE #{p}phoenix_kit_staff_people DROP COLUMN IF EXISTS middle_name")
    execute("ALTER TABLE #{p}phoenix_kit_staff_people DROP COLUMN IF EXISTS last_name")

    execute("ALTER TABLE #{p}phoenix_kit_staff_departments DROP COLUMN IF EXISTS translations")
    execute("ALTER TABLE #{p}phoenix_kit_staff_teams DROP COLUMN IF EXISTS translations")
    execute("ALTER TABLE #{p}phoenix_kit_staff_people DROP COLUMN IF EXISTS translations")

    drop_if_exists(table(:phoenix_kit_location_spaces, prefix: prefix))
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '121'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
