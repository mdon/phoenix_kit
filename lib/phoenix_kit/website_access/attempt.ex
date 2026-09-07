defmodule PhoenixKit.WebsiteAccess.Attempt do
  @moduledoc """
  One try at the website password gate.

  `verdict` says how it went: `"correct"`, `"case"` (the right letters in
  the wrong case — caps lock), `"close"` (a few characters off — a typo),
  `"unrelated"`, `"empty"`, `"locked"` (refused unjudged: the address was
  locked out), `"link"` (let in by the access link). `typed` holds what was
  entered — everything by default, only a near miss (`case`/`close`) or
  nothing, as the "keep what was typed" setting says.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @verdicts ~w(correct case close unrelated empty locked link)

  @type t :: %__MODULE__{
          uuid: String.t() | nil,
          verdict: String.t(),
          typed: String.t() | nil,
          address: String.t() | nil,
          user_agent: String.t() | nil,
          inserted_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_access_attempts" do
    field :verdict, :string
    field :typed, :string
    field :address, :string
    field :user_agent, :string

    timestamps(type: :naive_datetime_usec, updated_at: false)
  end

  @doc "The verdicts an attempt can carry."
  def verdicts, do: @verdicts

  @doc false
  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:verdict, :typed, :address, :user_agent])
    |> validate_required([:verdict])
    |> validate_inclusion(:verdict, @verdicts)
    |> update_change(:typed, &String.slice(&1, 0, 255))
    |> update_change(:user_agent, &String.slice(&1, 0, 512))
    |> validate_length(:address, max: 64)
  end
end
