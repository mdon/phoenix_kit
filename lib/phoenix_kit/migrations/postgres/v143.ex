defmodule PhoenixKit.Migrations.Postgres.V143 do
  @moduledoc """
  V143: Known-device history for new-login security alerts.

  `phoenix_kit_user_known_devices` remembers the (IP, hashed user-agent)
  pairs a user has previously signed in from. `PhoenixKitWeb.Users.Auth
  .log_in_user/3` checks this table on every login; an unrecognized pair
  is a "new device" and — when the `new_login_alert_enabled` setting is
  on — logs a `user.new_login_detected` activity entry and sends an email
  via `PhoenixKit.Users.Auth.UserNotifier.deliver_new_login_alert/2`.

  The user agent is stored pre-hashed (SHA-256 hex, matching
  `PhoenixKit.Utils.SessionFingerprint.hash_user_agent/1`) — the raw UA
  string is never persisted, only enough to recognize a repeat visit from
  the same browser/OS combination.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    create_if_not_exists table(:phoenix_kit_user_known_devices,
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

      add(:ip_address, :string, size: 45, null: false)
      add(:user_agent_hash, :string, size: 64, null: false)
      add(:browser, :string, size: 100)
      add(:os, :string, size: 100)
      add(:first_seen_at, :utc_datetime, null: false, default: fragment("now()"))
      add(:last_seen_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create_if_not_exists(index(:phoenix_kit_user_known_devices, [:user_uuid], prefix: prefix))

    create_if_not_exists(
      unique_index(
        :phoenix_kit_user_known_devices,
        [:user_uuid, :ip_address, :user_agent_hash],
        prefix: prefix,
        name: "phoenix_kit_known_devices_user_ip_ua_index"
      )
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '143'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(table(:phoenix_kit_user_known_devices, prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '142'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
