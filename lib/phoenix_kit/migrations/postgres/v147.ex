defmodule PhoenixKit.Migrations.Postgres.V147 do
  @moduledoc """
  V147: Persist geo-location on known devices.

  Adds a nullable `location` column to `phoenix_kit_user_known_devices`. The
  "City, Country" string is already resolved at new-device time by
  `PhoenixKit.Users.LoginAlerts` (it was only used in the alert email);
  storing it lets the user's Active Sessions list show where each session
  signed in from without an extra geo lookup per page render.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    alter table(:phoenix_kit_user_known_devices, prefix: prefix) do
      add_if_not_exists(:location, :string, size: 255)
    end

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '147'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    alter table(:phoenix_kit_user_known_devices, prefix: prefix) do
      remove_if_exists(:location, :string)
    end

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '146'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
