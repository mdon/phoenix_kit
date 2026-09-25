defmodule PhoenixKit.Modules.Storage.LocationCheck do
  @moduledoc """
  That an instance has been checked against every bucket (V204), when, and
  how many buckets held it.

  Written by `Storage.Workers.LocationBackfillJob` for every instance it
  visits (a miss included, `found_in: 0`), and by the writers that store an
  object (they know every bucket they wrote). A read that finds a key in a
  bucket its rows did not name records that location, but is not a check:
  the other copies may be elsewhere.

  Go through `PhoenixKit.Modules.Storage.Locations`.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:file_instance_uuid, UUIDv7, autogenerate: false}

  @type t :: %__MODULE__{
          file_instance_uuid: UUIDv7.t() | nil,
          checked_at: NaiveDateTime.t() | nil,
          found_in: non_neg_integer()
        }

  schema "phoenix_kit_file_location_checks" do
    field :checked_at, :naive_datetime
    field :found_in, :integer, default: 0
  end
end
