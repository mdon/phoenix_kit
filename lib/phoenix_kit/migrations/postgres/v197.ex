defmodule PhoenixKit.Migrations.Postgres.V197 do
  @moduledoc """
  V197: Failed sign-in attempts.

  `phoenix_kit_login_attempts` records sign-ins that did NOT succeed. Until
  now a wrong password produced a flash and nothing else: no activity entry,
  no row, nothing either the targeted account holder or the site owner could
  ever see. The only trace was Hammer's in-memory counter, which is node-local,
  lost on restart, and only says anything once a bucket overflows.

  Rows are **aggregated at write time** rather than one-per-attempt. The
  unique index is the dedup key, and the write is a single
  `INSERT ... ON CONFLICT DO UPDATE SET attempt_count = attempt_count + 1` —
  no read, no lock contention, and a brute-force run against one account from
  one network collapses into one row per hour instead of thousands.

  `bucket_start` is that hour, truncated by the caller
  (`PhoenixKit.Users.LoginAttempts`) rather than by a database default, so the
  value written and the value conflicted on are always the same one.

  `identifier` is what the person typed, normalized and truncated to 160
  characters — the same cap `PhoenixKitWeb.Users.Session` already applies
  before echoing it back into a flash. It is attacker-controlled text and must
  be treated as such by anything that renders it.

  `user_uuid` is NULL when the identifier matched no account, and the FK is
  `ON DELETE CASCADE` so deleting a user takes their attempt history with them.
  It is deliberately NOT part of the dedup key: NULL never equals NULL in a
  unique index, so keying on it would silently stop deduplicating for exactly
  the rows an attacker generates most of.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    create_if_not_exists table(:phoenix_kit_login_attempts,
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
        )
      )

      add(:identifier, :string, size: 160, null: false)
      add(:ip_address, :string, size: 45, null: false)
      add(:ip_network, :string, size: 45, null: false)
      add(:user_agent_hash, :string, size: 64)
      add(:browser, :string, size: 100)
      add(:os, :string, size: 100)
      add(:outcome, :string, size: 32, null: false)
      add(:attempt_count, :integer, null: false, default: 1)
      add(:bucket_start, :utc_datetime, null: false)
      add(:first_at, :utc_datetime, null: false, default: fragment("now()"))
      add(:last_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    # The dedup key. Index name stays bare on CREATE — it is qualified only on
    # DROP (see dev_docs/guides/2026-07-27-prefix-safe-migrations.md).
    create_if_not_exists(
      unique_index(
        :phoenix_kit_login_attempts,
        [:identifier, :ip_network, :outcome, :bucket_start],
        prefix: prefix,
        name: "phoenix_kit_login_attempts_dedup_index"
      )
    )

    # "What has been thrown at this account lately" — the account holder's
    # count and the admin's per-user view.
    create_if_not_exists(
      index(:phoenix_kit_login_attempts, [:user_uuid, :last_at],
        prefix: prefix,
        name: "phoenix_kit_login_attempts_user_last_at_index"
      )
    )

    # "What is this network doing" — the admin's per-IP view, and the only
    # useful grouping for attempts that matched no account.
    create_if_not_exists(
      index(:phoenix_kit_login_attempts, [:ip_network, :last_at],
        prefix: prefix,
        name: "phoenix_kit_login_attempts_network_last_at_index"
      )
    )

    # Pruning scans by age alone and must not table-scan.
    create_if_not_exists(
      index(:phoenix_kit_login_attempts, [:last_at],
        prefix: prefix,
        name: "phoenix_kit_login_attempts_last_at_index"
      )
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '197'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(table(:phoenix_kit_login_attempts, prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '196'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
