defmodule PhoenixKit.Migrations.Postgres.V150 do
  @moduledoc """
  V150: Readable device name on session tokens.

  Adds nullable `browser` and `os` columns to `phoenix_kit_users_tokens`,
  parsed from the User-Agent at login (V43 already stores the hashed UA for
  fingerprint matching — the raw string, and thus the readable name, was
  never kept). Storing the parsed name lets the user's Active Sessions list
  and the admin all-sessions view show "Safari on iOS" for every session,
  independent of the `new_login_alert_enabled` setting (which gates the
  richer, more sensitive geo-location via known-devices).

  Existing sessions predate the columns and show as "Unknown device" until
  their next sign-in — the raw UA was never stored, so there's nothing to
  backfill.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    alter table(:phoenix_kit_users_tokens, prefix: prefix) do
      add_if_not_exists(:browser, :string, size: 100)
      add_if_not_exists(:os, :string, size: 100)
    end

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '150'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    alter table(:phoenix_kit_users_tokens, prefix: prefix) do
      remove_if_exists(:browser, :string)
      remove_if_exists(:os, :string)
    end

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '149'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
