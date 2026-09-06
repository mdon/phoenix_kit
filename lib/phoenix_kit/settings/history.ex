defmodule PhoenixKit.Settings.History do
  @moduledoc """
  The history of site settings: what each setting was, and since when.

  ## Why

  A stored instant does not say which regime wrote it. When the `time_zone`
  setting moved from an integer offset to an IANA id and several modules
  turned out to have added that value to other instants, the rows they had
  written could not be repaired: nothing recorded when the setting changed
  or what it was before. `phoenix_kit_settings.date_updated` holds the last
  change only, and the activity feed prunes after 90 days. This table holds
  every change, forever.

  ## What is recorded

  Every write through `PhoenixKit.Settings` that changes a value — the
  admin pages, a module's own settings, a JSON setting — records one row
  with the value before and after, the actor when a person did it, and a
  `source`. A write that leaves the value as it was records nothing, so
  saving the settings page does not produce a row per field. A restricted
  (secret) setting records that a change happened and nothing else.

  ## Reading it

    * `list/2` — the changes to one key, newest first.
    * `value_at/2` — the value a key had at an instant: the answer to "which
      timezone was this site on when that row was written?".
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.HistoryEntry
  alias PhoenixKit.Settings.Setting

  @doc """
  Records the change a settings write made, or nothing when it changed no
  value.

  `changeset` is the one the write was made from (its `data` is the row as
  it was), `written` the row as stored. Options: `:actor_uuid` (nil for a
  module or a migration), `:source` (`"settings"` for the admin pages;
  default `"system"`).

  Returns `{:ok, %HistoryEntry{}}`, `{:ok, :unchanged}` or
  `{:error, changeset}`.
  """
  @spec record(Ecto.Changeset.t(), Setting.t(), keyword()) ::
          {:ok, HistoryEntry.t() | :unchanged} | {:error, Ecto.Changeset.t()}
  def record(%Ecto.Changeset{} = changeset, %Setting{} = written, opts \\ []) do
    old = value_of(changeset.data)
    new = value_of(written)

    # `data` is a bare struct on an insert: the key did not exist, so the
    # old value is "nothing" whatever the struct's field default says.
    old = if changeset.data.__meta__.state == :built, do: nil, else: old

    if old == new do
      {:ok, :unchanged}
    else
      restricted? = written.key in Settings.restricted_setting_keys()

      %HistoryEntry{}
      |> HistoryEntry.changeset(%{
        key: written.key,
        old_value: if(restricted?, do: nil, else: old),
        new_value: if(restricted?, do: nil, else: new),
        restricted: restricted?,
        actor_uuid: Keyword.get(opts, :actor_uuid),
        source: Keyword.get(opts, :source) || "system"
      })
      |> RepoHelper.repo().insert(log: false)
    end
  end

  # A setting's value as history sees it: the JSON encoded when the setting
  # is a JSON one (an empty document is a value too — "{}" — not "nothing"),
  # else the string. `nil` when there is neither.
  defp value_of(%Setting{value_json: json}) when not is_nil(json), do: Jason.encode!(json)
  defp value_of(%Setting{value: value}), do: value

  @doc """
  The changes to `key`, newest first. `:limit` (default 100).
  """
  @spec list(String.t(), keyword()) :: [HistoryEntry.t()]
  def list(key, opts \\ []) when is_binary(key) do
    limit = Keyword.get(opts, :limit, 100)

    HistoryEntry
    |> where([h], h.key == ^key)
    |> order_by([h], desc: h.inserted_at, desc: h.uuid)
    |> limit(^limit)
    |> RepoHelper.repo().all()
  end

  @doc """
  The value `key` had at `instant`.

  The newest change at or before the instant says what the value became;
  with none, the oldest change after it says what the value was before
  anything was recorded; with no history at all, the current value — a
  setting that was never changed since recording began has always been what
  it is now. `nil` for a restricted key's withheld value, and for a key with
  no history that has no current value either.
  """
  @spec value_at(String.t(), DateTime.t() | NaiveDateTime.t()) :: String.t() | nil
  def value_at(key, %DateTime{} = instant), do: value_at(key, DateTime.to_naive(instant))

  def value_at(key, %NaiveDateTime{} = instant) when is_binary(key) do
    at_or_before =
      HistoryEntry
      |> where([h], h.key == ^key and h.inserted_at <= ^instant)
      |> order_by([h], desc: h.inserted_at, desc: h.uuid)
      |> limit(1)
      |> RepoHelper.repo().one()

    case at_or_before do
      %HistoryEntry{new_value: value} ->
        value

      nil ->
        after_it =
          HistoryEntry
          |> where([h], h.key == ^key and h.inserted_at > ^instant)
          |> order_by([h], asc: h.inserted_at, asc: h.uuid)
          |> limit(1)
          |> RepoHelper.repo().one()

        case after_it do
          %HistoryEntry{old_value: value} -> value
          nil -> Settings.get_setting(key)
        end
    end
  end
end
