defmodule PhoenixKit.Migrations.Postgres.V196 do
  @moduledoc """
  V196: a user's Google address.

  Adds `google_email` to `phoenix_kit_users`. Sharing something with a user
  through Google (a Drive file, a calendar invite) needs the address their
  Google account actually answers to, which is not always the address they
  registered with.

  The column is nullable and unconstrained: a Google address is optional,
  several users may legitimately share one (a team inbox), and nothing
  authenticates against it — `email` stays the identity.

  The up also backfills it from `phoenix_kit_user_oauth_providers`: a user
  who has linked a Google sign-in already proved that address to us, so
  their column starts filled rather than waiting for their next sign-in.
  Only rows whose `provider_email` is present are copied, and only where
  `google_email` is still NULL, so the backfill is re-runnable and never
  overwrites a hand-entered value. A user with more than one Google link
  (the table allows one row per provider per user, but a repaired install
  may carry duplicates) takes the most recently updated one.

  Additive only; re-runnable.
  """

  use Ecto.Migration

  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V196 back: drops the column. Hand-entered addresses are lost; linked Google accounts are untouched."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  # The exact statements `up/1` runs, for the migration test. `prefix` is the
  # bare schema name.
  def up_statements(prefix) do
    p = prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_users ADD COLUMN IF NOT EXISTS google_email character varying(160)",
      backfill_statement(prefix),
      "COMMENT ON TABLE #{p}phoenix_kit IS '196'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_users DROP COLUMN IF EXISTS google_email",
      "COMMENT ON TABLE #{p}phoenix_kit IS '195'"
    ]
  end

  # DISTINCT ON picks one row per user — the freshest link — so a duplicated
  # provider row can't make the UPDATE ambiguous.
  defp backfill_statement(prefix) do
    p = prefix_str(prefix)

    """
    UPDATE #{p}phoenix_kit_users u
    SET google_email = src.provider_email
    FROM (
      SELECT DISTINCT ON (user_uuid) user_uuid, provider_email
      FROM #{p}phoenix_kit_user_oauth_providers
      WHERE provider = 'google'
        AND provider_email IS NOT NULL
        AND provider_email <> ''
      ORDER BY user_uuid, updated_at DESC
    ) AS src
    WHERE src.user_uuid = u.uuid
      AND u.google_email IS NULL
    """
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
