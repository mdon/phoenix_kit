defmodule PhoenixKit.Users.ViewPref do
  @moduledoc """
  What one user chose for one view: `prefs` is a JSON object of top-level
  fields (a table's `"columns"`, and whatever else the view's owner keeps),
  keyed by the view's `key`. One row per `(user_uuid, key)`.

  Written only through `PhoenixKit.Users.ViewPrefs`, which patches fields
  in the upsert itself rather than through a changeset.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_user_view_prefs" do
    field :user_uuid, UUIDv7
    field :key, :string
    field :prefs, :map, default: %{}

    timestamps(type: :utc_datetime)
  end
end
