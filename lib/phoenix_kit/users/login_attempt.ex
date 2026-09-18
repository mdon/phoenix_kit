defmodule PhoenixKit.Users.LoginAttempt do
  @moduledoc """
  A sign-in that did not succeed, aggregated into an hourly bucket.

  One row is NOT one attempt. The unique index
  `(identifier, ip_network, outcome, bucket_start)` is a dedup key, and
  `PhoenixKit.Users.LoginAttempts.record/1` upserts into it, so a brute-force
  run against one account from one network collapses to one row per hour with
  a rising `attempt_count`. Read `attempt_count`, never `count(*)`.

  ## Fields worth knowing about

    * `identifier` — what the person typed, normalized (trimmed, downcased)
      and truncated to 160 characters. **Attacker-controlled text.** It is
      stored verbatim because "someone is hammering `admin@`" is a thing a
      site owner wants to see, but anything rendering it must escape it, and
      it is never used to build a query fragment.

    * `user_uuid` — `nil` when the identifier matched no account. Kept out of
      the dedup key on purpose: NULL never equals NULL in a Postgres unique
      index, so keying on it would silently stop deduplicating exactly the
      rows an attacker generates most of.

    * `outcome` — why it failed. `"invalid_credentials"` (wrong password, or
      no such account), `"rate_limited"` (rejected before credentials were
      even checked), `"inactive"` (correct password, deactivated account).
      The last is the interesting one: someone has the password.

    * `bucket_start` — the hour, truncated by the caller rather than by a
      database default, so the value written and the value conflicted on are
      always the same one.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  alias PhoenixKit.Users.Auth.User

  @outcomes ~w(invalid_credentials rate_limited inactive)

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_login_attempts" do
    field :identifier, :string
    field :ip_address, :string
    field :ip_network, :string
    field :user_agent_hash, :string
    field :browser, :string
    field :os, :string
    field :outcome, :string
    field :attempt_count, :integer, default: 1
    field :bucket_start, :utc_datetime
    field :first_at, :utc_datetime
    field :last_at, :utc_datetime

    belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7
  end

  @doc "The outcomes `outcome` may take."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc false
  def changeset(attempt, attrs) do
    attempt
    |> Ecto.Changeset.cast(attrs, [
      :user_uuid,
      :identifier,
      :ip_address,
      :ip_network,
      :user_agent_hash,
      :browser,
      :os,
      :outcome,
      :attempt_count,
      :bucket_start,
      :first_at,
      :last_at
    ])
    |> Ecto.Changeset.validate_required([
      :identifier,
      :ip_address,
      :ip_network,
      :outcome,
      :bucket_start,
      :first_at,
      :last_at
    ])
    |> Ecto.Changeset.validate_inclusion(:outcome, @outcomes)
    |> Ecto.Changeset.unique_constraint([:identifier, :ip_network, :outcome, :bucket_start],
      name: :phoenix_kit_login_attempts_dedup_index
    )
  end
end
