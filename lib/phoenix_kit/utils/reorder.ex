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

  Non-UUID entries in the payload are silently filtered (a stale or
  malformed drop event can't poison the rewrite). Duplicates dedup
  last-write-wins via `Enum.uniq/1`.

  ## Example

      defmodule MyApp.Endpoints do
        alias PhoenixKit.Utils.Reorder

        def reorder_endpoints(ordered_ids) do
          Reorder.reorder(MyApp.Endpoint, ordered_ids, :sort_order, repo: repo())
        end
      end
  """

  import Ecto.Query

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
  - `:max_uuids` — payload cap, checked after dedup. Default `500`.
    Guards against runaway drop events from a misbehaving client.
  """
  @spec reorder(module(), [String.t()], atom(), keyword()) :: result()
  def reorder(schema, ordered_ids, field, opts \\ [])
      when is_atom(schema) and is_list(ordered_ids) and is_atom(field) do
    max = Keyword.get(opts, :max_uuids, @default_max_uuids)
    repo = Keyword.get(opts, :repo, PhoenixKit.RepoHelper.repo())

    case dedupe_uuids(ordered_ids) do
      [] ->
        {:ok, 0}

      uuids when length(uuids) > max ->
        {:error, :too_many_uuids}

      uuids ->
        {:ok, count} =
          repo.transaction(fn ->
            pairs = Enum.with_index(uuids, 1)
            _ = write_phase(repo, schema, pairs, field, -1)
            write_phase(repo, schema, pairs, field, 1)
          end)

        {:ok, count}
    end
  end

  defp write_phase(repo, schema, pairs, field, sign) do
    Enum.reduce(pairs, 0, fn {uuid, idx}, total ->
      {n, _} =
        from(r in schema, where: r.uuid == ^uuid)
        |> repo.update_all(set: [{field, sign * idx}])

      total + n
    end)
  end

  defp dedupe_uuids(ids) do
    ids
    |> Enum.filter(&PhoenixKit.Utils.UUID.valid?/1)
    |> Enum.uniq()
  end
end
