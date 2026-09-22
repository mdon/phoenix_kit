defmodule PhoenixKit.Utils.TreeQuery do
  @moduledoc """
  Recursive queries over a self-referencing table — a schema whose rows
  point at a parent row of the same schema (`parent_uuid` by default).
  Each call is one recursive CTE: subtrees for cascades and moves,
  ancestors for breadcrumbs and cycle checks.

  Cycle-safe: the CTEs use `UNION`, not `UNION ALL`, so Postgres drops rows
  it has already seen and a corrupt parent cycle ends the recursion instead
  of looping.

  Uuids come back as strings, in no particular order.

      TreeQuery.subtree_uuids(Category, [category.uuid])
      TreeQuery.ancestor_uuids(Space, space.uuid, parent: :parent_space_uuid)

  ## Options

    * `:parent` — the parent-id field (default `:parent_uuid`)
    * `:repo` — the repo (default `PhoenixKit.RepoHelper.repo/0`)
  """

  import Ecto.Query

  @doc """
  `roots` and every row below them — the union of their subtrees, each
  uuid once. `[]` for no roots.
  """
  @spec subtree_uuids(module(), [String.t()], keyword()) :: [String.t()]
  def subtree_uuids(schema, roots, opts \\ [])

  def subtree_uuids(_schema, [], _opts), do: []

  def subtree_uuids(schema, roots, opts) when is_atom(schema) and is_list(roots) do
    parent = Keyword.get(opts, :parent, :parent_uuid)

    initial =
      from(r in schema,
        where: r.uuid in type(^roots, {:array, UUIDv7}),
        select: %{uuid: r.uuid}
      )

    recursion =
      from(r in schema,
        join: t in "pk_tree_down",
        on: field(r, ^parent) == t.uuid,
        select: %{uuid: r.uuid}
      )

    from(t in "pk_tree_down", select: t.uuid)
    |> recursive_ctes(true)
    |> with_cte("pk_tree_down", as: ^union(initial, ^recursion))
    |> repo(opts).all()
    |> Enum.map(&load_uuid/1)
  end

  @doc "Every row below `uuid`, not `uuid` itself. `[]` for a leaf."
  @spec descendant_uuids(module(), String.t(), keyword()) :: [String.t()]
  def descendant_uuids(schema, uuid, opts \\ []) when is_binary(uuid),
    do: subtree_uuids(schema, [uuid], opts) -- [uuid]

  @doc "Every row above `uuid`, up to the top — not `uuid` itself."
  @spec ancestor_uuids(module(), String.t(), keyword()) :: [String.t()]
  def ancestor_uuids(schema, uuid, opts \\ []) when is_atom(schema) and is_binary(uuid) do
    parent = Keyword.get(opts, :parent, :parent_uuid)

    initial =
      from(r in schema,
        where: r.uuid == type(^uuid, UUIDv7),
        select: %{uuid: r.uuid, parent: field(r, ^parent)}
      )

    recursion =
      from(r in schema,
        join: t in "pk_tree_up",
        on: r.uuid == t.parent,
        select: %{uuid: r.uuid, parent: field(r, ^parent)}
      )

    from(t in "pk_tree_up", select: t.uuid)
    |> recursive_ctes(true)
    |> with_cte("pk_tree_up", as: ^union(initial, ^recursion))
    |> repo(opts).all()
    |> Enum.map(&load_uuid/1)
    |> List.delete(uuid)
  end

  defp repo(opts), do: Keyword.get_lazy(opts, :repo, &PhoenixKit.RepoHelper.repo/0)

  # The CTE's outer query is schema-less, so Postgres hands the uuid back
  # in its raw 16-byte form.
  defp load_uuid(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp load_uuid(uuid) when is_binary(uuid), do: uuid
end
