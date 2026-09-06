defmodule PhoenixKit.Settings.HistoryEntry do
  @moduledoc """
  One change to a site setting: the value before and after, who made it,
  where it came from, and when. Rows are written by
  `PhoenixKit.Settings.History.record/3` on every settings write that
  changes a value, and never pruned.

  A restricted (secret) setting records that a change happened with both
  values withheld — `restricted` is true and the values are nil.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: String.t() | nil,
          key: String.t(),
          old_value: String.t() | nil,
          new_value: String.t() | nil,
          restricted: boolean(),
          actor_uuid: String.t() | nil,
          source: String.t(),
          inserted_at: NaiveDateTime.t() | nil
        }

  schema "phoenix_kit_settings_history" do
    field :key, :string
    field :old_value, :string
    field :new_value, :string
    field :restricted, :boolean, default: false
    field :actor_uuid, UUIDv7
    field :source, :string, default: "system"

    timestamps(type: :naive_datetime, updated_at: false)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:key, :old_value, :new_value, :restricted, :actor_uuid, :source])
    |> validate_required([:key, :source])
    |> validate_length(:key, min: 1, max: 255)
    |> validate_length(:source, min: 1, max: 64)
    |> foreign_key_constraint(:actor_uuid)
  end
end
