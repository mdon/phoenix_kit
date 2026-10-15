defmodule PhoenixKit.Migrations.Postgres.V219 do
  @moduledoc """
  V219: API keys and service users.

  Two additions, both for the shop API (admin and public):

    * **`phoenix_kit_users.api_only`** (`boolean`, `NOT NULL`, default `false`). A
      *service user* is an account that owns API keys and never signs in on the
      web. Every web authentication entry point refuses an `api_only` user
      (password login, magic link, password reset, OAuth, QR login, registration
      confirmation, impersonation and the session read itself). Every existing
      user reads `false`.
    * **`phoenix_kit_api_keys`**, one row per bearer key:

        * `user_uuid` is the owner (the key acts with the owner's permissions).
          `ON DELETE CASCADE`: deleting the owner deletes the key.
        * `created_by_uuid` is who issued it. `ON DELETE SET NULL`: the key
          outlives the person who created it.
        * `prefix` is 8 lowercase hex characters, unique. A token is
          `pk_<prefix>_<secret>`; a request finds the row by `prefix`.
        * `secret_hash` is the SHA-256 of the 32-byte secret. The secret itself
          is never stored.
        * `scopes` and `allowed_ips` are `text[]` (empty array = none / any).
        * `requires_approval` marks a key whose dangerous operations wait for a
          human.
        * `expires_at`, `revoked_at`, `last_used_at`, `last_used_ip` are
          timestamps and the last client address.

  No key is created by the migration.

  ## Locks

  `ADD COLUMN ... NOT NULL DEFAULT false` with a constant default (no table
  rewrite), then a new table. Re-runnable.

  ## Down

  Drops `phoenix_kit_api_keys` (every key is lost) and `api_only`. A service user then
  stays as an account with an undeliverable address and a random password hash, so
  nobody can sign in as it either; delete such accounts before rolling back.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKit.Migrations.Postgres.V203

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V219 back: the keys table and the `api_only` flag go."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)
    keys = "#{p}phoenix_kit_api_keys"

    [
      "ALTER TABLE #{p}phoenix_kit_users ADD COLUMN IF NOT EXISTS api_only boolean DEFAULT false NOT NULL",
      """
      CREATE TABLE IF NOT EXISTS #{keys} (
        uuid uuid DEFAULT #{Helpers.uuid_v7_call(prefix)} NOT NULL,
        user_uuid uuid NOT NULL,
        created_by_uuid uuid,
        name character varying(160) NOT NULL,
        prefix character varying(8) NOT NULL,
        secret_hash bytea NOT NULL,
        scopes text[] DEFAULT '{}'::text[] NOT NULL,
        requires_approval boolean DEFAULT false NOT NULL,
        allowed_ips text[] DEFAULT '{}'::text[] NOT NULL,
        expires_at timestamp(0) without time zone,
        revoked_at timestamp(0) without time zone,
        last_used_at timestamp(0) without time zone,
        last_used_ip character varying(45),
        inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_api_keys_pkey PRIMARY KEY (uuid),
        CONSTRAINT phoenix_kit_api_keys_user_uuid_fkey FOREIGN KEY (user_uuid)
          REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE,
        CONSTRAINT phoenix_kit_api_keys_created_by_uuid_fkey FOREIGN KEY (created_by_uuid)
          REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
        CONSTRAINT phoenix_kit_api_keys_prefix_check CHECK (prefix ~ '^[0-9a-f]{8}$')
      )
      """,
      # A request finds its key by prefix.
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_api_keys_prefix_index ON #{keys} (prefix)",
      # "The keys of this owner", and the cascade of a user delete.
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_keys_user_uuid_index ON #{keys} (user_uuid)",
      # The SET NULL of a user delete must not scan the table.
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_keys_created_by_uuid_index ON #{keys} (created_by_uuid)",
      "COMMENT ON TABLE #{p}phoenix_kit IS '219'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "DROP TABLE IF EXISTS #{p}phoenix_kit_api_keys",
      "ALTER TABLE #{p}phoenix_kit_users DROP COLUMN IF EXISTS api_only",
      "COMMENT ON TABLE #{p}phoenix_kit IS '218'"
    ]
  end
end
