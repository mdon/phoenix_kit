defmodule PhoenixKit.Migrations.Postgres.V03 do
  use Ecto.Migration

  @doc """
  Run the V03 migration to add settings table.
  """
  def up(%{prefix: prefix} = _opts) do
    create_if_not_exists table(:phoenix_kit_settings, prefix: prefix) do
      add :key, :string, null: false
      add :value, :string, null: false
      add :date_added, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :date_updated, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    create_if_not_exists unique_index(:phoenix_kit_settings, [:key],
                           name: :phoenix_kit_settings_key_uidx,
                           prefix: prefix
                         )

    # Insert system settings
    execute """
    INSERT INTO #{inspect(prefix)}.phoenix_kit_settings (key, value, date_added, date_updated)
    VALUES
      ('time_zone', '0', NOW(), NOW()),
      ('date_format', 'Y-m-d', NOW(), NOW()),
      ('time_format', 'H:i', NOW(), NOW())

    ON CONFLICT (key) DO NOTHING
    """

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '3'"
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
