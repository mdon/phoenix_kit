defmodule PhoenixKit.Utils.Reorder do
  @moduledoc """
  Two-phase index rewrite for drag-to-reorder list views.

  Given a list of UUIDs in their new display order and an Ecto schema,
  rewrites a position field on the matching rows to `1..N` matching
  the order of the input list. The write runs in two passes inside a
  transaction — first to negative indices, then to positive — so a
  unique index on the position column (should one ever be added)
  wouldn't trip mid-update.

  Consumers that need pre-write validation (scope checks, permission
  guards) or post-write side effects (activity logging, PubSub
  broadcasts) should wrap this helper rather than fold the logic in
  here. `PhoenixKitProjects.reorder_projects/2` is the reference
  consumer doing exactly that — this module owns only the index-rewrite
  primitive.

  Rows are matched on `uuid` by default; pass `key: :id` (any field) for
  a schema keyed some other way — an integer primary key, a slug. The
  payload's ids are cast with that field's Ecto type, so the strings a
  drag hook sends (`"42"`) match an integer column.

  Entries that are not a valid key (a non-UUID for `:uuid`, a non-integer
  for an integer key) are silently filtered — a stale or malformed drop
  event can't poison the rewrite. Duplicates dedup last-write-wins via
  `Enum.uniq/1`.

  ## Example

      defmodule MyApp.Endpoints do
        alias PhoenixKit.Utils.Reorder

        def reorder_endpoints(ordered_ids) do
          Reorder.reorder(MyApp.Endpoint, ordered_ids, :sort_order, repo: repo())
        end
      end
  """

  import Ecto.Query

  alias PhoenixKit.Utils.UUID

  @default_max_uuids 500

  @type result :: {:ok, non_neg_integer()} | {:error, :too_many_uuids}

  @doc """
  Rewrites `field` on the rows whose `uuid` appears in `ordered_ids`,
  setting it to each UUID's 1-based position in the list.

  Returns `{:ok, count}` where `count` is the number of rows actually
  updated in the positive-write phase (matches `Repo.update_all`'s
  count semantics — UUIDs in the payload that don't resolve to real
  rows aren't counted). Returns `{:error, :too_many_uuids}` when the
  dedup'd payload exceeds the configured cap. An empty / fully-filtered
  payload returns `{:ok, 0}`.

  ## Options

  - `:repo` — the Ecto repo to use. Defaults to
    `PhoenixKit.RepoHelper.repo/0` so it picks up the host app's repo.
  - `:key` — the field the ids are matched on. Default `:uuid`.
  - `:max_ids` (or the older `:max_uuids`) — payload cap, checked after
    dedup. Default `500`. Guards against runaway drop events from a
    misbehaving client.
  """
  @spec reorder(module(), [String.t() | integer()], atom(), keyword()) :: result()
  def reorder(schema, ordered_ids, field, opts \\ [])
      when is_atom(schema) and is_list(ordered_ids) and is_atom(field) do
    max = Keyword.get(opts, :max_ids) || Keyword.get(opts, :max_uuids, @default_max_uuids)
    repo = Keyword.get(opts, :repo, PhoenixKit.RepoHelper.repo())
    key = Keyword.get(opts, :key, :uuid)

    case dedupe_ids(ordered_ids, schema, key) do
      [] ->
        {:ok, 0}

      uuids when length(uuids) > max ->
        {:error, :too_many_uuids}

      uuids ->
        {:ok, count} =
          repo.transaction(fn ->
            pairs = Enum.with_index(uuids, 1)
            _ = write_phase(repo, schema, key, pairs, field, -1)
            write_phase(repo, schema, key, pairs, field, 1)
          end)

        {:ok, count}
    end
  end

  defp write_phase(repo, schema, key, pairs, field, sign) do
    Enum.reduce(pairs, 0, fn {id, idx}, total ->
      {n, _} =
        from(r in schema, where: field(r, ^key) == ^id)
        |> repo.update_all(set: [{field, sign * idx}])

      total + n
    end)
  end

  # `:uuid` keeps its own validity check (the schema's type may be a
  # custom UUIDv7 module); any other key casts with the field's Ecto type.
  defp dedupe_ids(ids, _schema, :uuid) do
    ids
    |> Enum.filter(&(is_binary(&1) and UUID.valid?(&1)))
    |> Enum.uniq()
  end

  defp dedupe_ids(ids, schema, key) do
    type = schema.__schema__(:type, key) || :string

    ids
    |> Enum.flat_map(fn id ->
      case Ecto.Type.cast(type, id) do
        {:ok, value} when not is_nil(value) -> [value]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end
end
