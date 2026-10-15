defmodule PhoenixKit.Migrations.Postgres.V220 do
  @moduledoc """
  V220: the dangerous-operation flow of the shop API.

  Two tables:

    * **`phoenix_kit_api_confirmations`**, one row per confirmation code
      (`kind = 'token'`) or approval request (`kind = 'approval'`) of a
      dangerous API operation.

        * `tool`, `input_hash` and `fingerprint` bind a code to one tool, one
          set of arguments and the values those arguments touch.
        * `input` keeps the arguments of an approval until it is decided or
          expires (then it is set to `NULL`); `context` keeps the language,
          currency and base URL of the original request.
        * `actor_key_uuid` is the API key (deleted with it); `cart_token_hash`
          is the actor of a public tool's code.
        * `status` is `unused | used | expired` for a code and `pending |
          approved | executing | executed | failed | rejected | stale |
          expired` for an approval.
        * `decided_by_uuid` is the person who approved or rejected.
        * `notified_at` throttles the "approval waiting" notice.

    * **`phoenix_kit_api_idempotency`**, one row per `Idempotency-Key` an API
      client used: `(scope_ref, key)` is unique, `request_hash` tells a retry
      from a different request, `state` is `in_progress | done`, `locked_at`
      is the start of the lease, and `response` holds the exact JSON body of a
      stored `200` answer.

  No row is created by the migration.

  ## Locks

  Two `CREATE TABLE`s and six indexes on empty tables. Re-runnable.

  ## Down

  Drops both tables: every pending approval, unused code and stored idempotent
  response is lost.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKit.Migrations.Postgres.V203

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V220 back: both tables go."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)
    conf = "#{p}phoenix_kit_api_confirmations"
    idem = "#{p}phoenix_kit_api_idempotency"

    [
      """
      CREATE TABLE IF NOT EXISTS #{conf} (
        uuid uuid DEFAULT #{Helpers.uuid_v7_call(prefix)} NOT NULL,
        kind character varying(16) NOT NULL,
        tool character varying(120) NOT NULL,
        input_hash character varying(64) NOT NULL,
        fingerprint character varying(64) NOT NULL,
        input jsonb,
        context jsonb DEFAULT '{}'::jsonb NOT NULL,
        actor_key_uuid uuid,
        cart_token_hash character varying(64),
        preview jsonb DEFAULT '{}'::jsonb NOT NULL,
        status character varying(16) NOT NULL,
        expires_at timestamp(0) without time zone NOT NULL,
        used_at timestamp(0) without time zone,
        decided_by_uuid uuid,
        decided_at timestamp(0) without time zone,
        result jsonb,
        notified_at timestamp(0) without time zone,
        inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_api_confirmations_pkey PRIMARY KEY (uuid),
        CONSTRAINT phoenix_kit_api_confirmations_actor_key_uuid_fkey FOREIGN KEY (actor_key_uuid)
          REFERENCES #{p}phoenix_kit_api_keys(uuid) ON DELETE CASCADE,
        CONSTRAINT phoenix_kit_api_confirmations_decided_by_uuid_fkey FOREIGN KEY (decided_by_uuid)
          REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
        CONSTRAINT phoenix_kit_api_confirmations_kind_check
          CHECK (kind IN ('token', 'approval')),
        CONSTRAINT phoenix_kit_api_confirmations_status_check
          CHECK (status IN ('unused', 'used', 'expired', 'pending', 'approved', 'executing', 'executed', 'failed', 'rejected', 'stale')),
        CONSTRAINT phoenix_kit_api_confirmations_actor_check
          CHECK (actor_key_uuid IS NOT NULL OR cart_token_hash IS NOT NULL)
      )
      """,
      # Pending lists and the per-key cap.
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_confirmations_actor_status_index ON #{conf} (actor_key_uuid, status)",
      # The expiry sweep.
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_confirmations_expires_at_index ON #{conf} (expires_at)",
      # The SET NULL of a user delete must not scan the table.
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_confirmations_decided_by_uuid_index ON #{conf} (decided_by_uuid)",
      # The stuck-operation sweep (`Confirm.sweep_stuck/2`): only approvals that are
      # running are in it, so it stays small however many unused codes the table holds.
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_confirmations_active_updated_at_index ON #{conf} (updated_at) WHERE status IN ('approved', 'executing')",
      """
      CREATE TABLE IF NOT EXISTS #{idem} (
        uuid uuid DEFAULT #{Helpers.uuid_v7_call(prefix)} NOT NULL,
        scope_ref character varying(64) NOT NULL,
        key character varying(128) NOT NULL,
        request_hash character varying(64) NOT NULL,
        state character varying(16) NOT NULL,
        locked_at timestamp without time zone NOT NULL,
        response text,
        expires_at timestamp(0) without time zone NOT NULL,
        inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_api_idempotency_pkey PRIMARY KEY (uuid),
        CONSTRAINT phoenix_kit_api_idempotency_state_check
          CHECK (state IN ('in_progress', 'done'))
      )
      """,
      # insert-first claim, and the lookup of a retry.
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_api_idempotency_scope_key_index ON #{idem} (scope_ref, key)",
      # The prune.
      "CREATE INDEX IF NOT EXISTS phoenix_kit_api_idempotency_expires_at_index ON #{idem} (expires_at)",
      "COMMENT ON TABLE #{p}phoenix_kit IS '220'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "DROP TABLE IF EXISTS #{p}phoenix_kit_api_idempotency",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_api_confirmations",
      "COMMENT ON TABLE #{p}phoenix_kit IS '219'"
    ]
  end
end
