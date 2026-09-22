defmodule PhoenixKit.Utils.Tree do
  @moduledoc """
  Nested trees for pickers (`PhoenixKitWeb.Components.TreePicker`): built
  from a flat, parent-linked list, and the pure operations a picker needs
  over them — so no module shows nested records as an indented flat list.

  A node is `%{id, name, children}` plus optional keys:

    * `:type` — an atom the picker filters on (`pickable`, `path_skip`)
    * `:icon` — a heroicon name for the row
    * `:hint` — short text beside the name ("top level")
    * `:badge` — a small badge after the name ("Archived")

  Any other key a module puts on a node rides along untouched.

  Ids are strings. `"root"` (`root_id/0`) is the conventional id of a row
  standing for "no parent" — a picker posts it as `""`.

      rows
      |> Tree.from_flat(node: &%{name: &1.title, type: :page})
      |> Tree.prune([record.uuid])
      |> then(&[Tree.root(gettext("Top level"), &1)])
  """

  @type tree_node :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:children) => [tree_node()],
          optional(:type) => atom(),
          optional(:icon) => String.t(),
          optional(:hint) => String.t(),
          optional(:badge) => String.t(),
          # A module's own keys ride along untouched (catalogue's `archived?`).
          optional(atom()) => term()
        }

  @root "root"

  @doc "The id of the row that stands for \"no parent\"."
  @spec root_id() :: String.t()
  def root_id, do: @root

  @doc """
  A row standing for "no parent", named `name`, holding `children`.
  `opts` may set `:hint` and `:icon` (default `"hero-home"`).
  """
  @spec root(String.t(), [tree_node()], keyword()) :: tree_node()
  def root(name, children, opts \\ []) do
    %{
      id: @root,
      type: :root,
      name: name,
      icon: Keyword.get(opts, :icon, "hero-home"),
      children: children
    }
    |> put_present(:hint, Keyword.get(opts, :hint))
  end

  defp put_present(node, _key, nil), do: node
  defp put_present(node, key, value), do: Map.put(node, key, value)

  @doc """
  Builds the tree from a flat list of records linked by a parent id.

  A record whose parent is not in the list is a root — so a list that
  leaves out trashed rows keeps their children, one level up. Building
  walks down from the roots, so a corrupt parent cycle can never loop:
  nothing in a cycle is reachable from a root. Sibling order is the list's
  order.

  ## Options

    * `:id` — the record's id (default `& &1.uuid`)
    * `:parent` — its parent's id or `nil` (default `& &1.parent_uuid`)
    * `:node` — the node's own keys (default `&%{name: &1.name}`); `:id`
      and `:children` are filled in
  """
  @spec from_flat([term()], keyword()) :: [tree_node()]
  def from_flat(records, opts \\ []) when is_list(records) do
    id_of = Keyword.get(opts, :id, & &1.uuid)
    parent_of = Keyword.get(opts, :parent, & &1.parent_uuid)
    node_of = Keyword.get(opts, :node, &%{name: &1.name})

    ids = MapSet.new(records, &to_string(id_of.(&1)))

    by_parent =
      Enum.group_by(records, fn record ->
        parent = parent_of.(record)
        if parent && MapSet.member?(ids, to_string(parent)), do: to_string(parent), else: nil
      end)

    level(nil, by_parent, id_of, node_of)
  end

  defp level(parent, by_parent, id_of, node_of) do
    for record <- Map.get(by_parent, parent, []) do
      id = to_string(id_of.(record))

      record
      |> node_of.()
      |> Map.merge(%{id: id, children: level(id, by_parent, id_of, node_of)})
    end
  end

  @doc "Applies `fun` to every node, children first."
  @spec map_nodes([tree_node()], (tree_node() -> tree_node())) :: [tree_node()]
  def map_nodes(tree, fun),
    do: Enum.map(tree, fn node -> fun.(%{node | children: map_nodes(node.children, fun)}) end)

  @doc """
  The tree without the rows in `ids` and everything under them — a record
  cannot move into its own subtree.
  """
  @spec prune([tree_node()], [String.t()]) :: [tree_node()]
  def prune(tree, []), do: tree

  def prune(tree, ids) do
    drop = MapSet.new(ids, &to_string/1)

    for node <- tree,
        not MapSet.member?(drop, node.id),
        do: %{node | children: prune(node.children, ids)}
  end

  @doc "The row with `id`, or `nil`."
  @spec find([tree_node()], term()) :: tree_node() | nil
  def find(tree, id) when is_binary(id) do
    case chain(tree, id) do
      [node | _] -> node
      [] -> nil
    end
  end

  def find(_tree, _id), do: nil

  @doc """
  Whether the tree offers `id` as a row of one of `types` — `:all` for any
  row. A picker checks a picked id with this before taking it.
  """
  @spec member?([tree_node()], term(), [atom()] | :all) :: boolean()
  def member?(tree, id, types \\ :all) do
    case find(tree, id) do
      nil -> false
      node -> of_type?(node, types)
    end
  end

  @doc false
  @spec of_type?(tree_node(), [atom()] | :all) :: boolean()
  def of_type?(_node, :all), do: true
  def of_type?(node, types), do: Map.get(node, :type) in types

  @doc """
  The names from the top down to `id`. `skip` leaves rows of those types
  out of the path. `[]` when the tree lacks it.
  """
  @spec path([tree_node()], term(), [atom()]) :: [String.t()]
  def path(tree, id, skip \\ [])

  def path(tree, id, skip) when is_binary(id) do
    tree
    |> chain(id)
    |> Enum.reverse()
    |> Enum.reject(&(Map.get(&1, :type) in skip))
    |> Enum.map(& &1.name)
  end

  def path(_tree, _id, _skip), do: []

  @doc "The ids of the rows above `id`, top first — what to open to show it."
  @spec ancestor_ids([tree_node()], term()) :: [String.t()]
  def ancestor_ids(tree, id) when is_binary(id) do
    case chain(tree, id) do
      [_self | above] -> above |> Enum.reverse() |> Enum.map(& &1.id)
      [] -> []
    end
  end

  def ancestor_ids(_tree, _id), do: []

  # The row with `id` followed by its ancestors (nearest first); [] when
  # the tree has no such row.
  defp chain(nodes, id) do
    Enum.find_value(nodes, [], fn node ->
      cond do
        node.id == id -> [node]
        (found = chain(node.children, id)) != [] -> found ++ [node]
        true -> nil
      end
    end)
  end

  @doc """
  The tree cut down to the rows whose name contains `query` (case and
  accents ignored) and the rows above them, plus the ids to open so every
  match shows. A matching row keeps its whole subtree, closed — finding a
  parent still lets the admin open it and pick a child. A blank query
  returns the tree untouched and opens nothing.
  """
  @spec filter([tree_node()], String.t()) :: {[tree_node()], [String.t()]}
  def filter(tree, query) do
    case fold(query) do
      "" -> {tree, []}
      needle -> filter_level(tree, needle)
    end
  end

  defp filter_level(nodes, needle), do: Enum.reduce(nodes, {[], []}, &filter_node(&1, needle, &2))

  defp filter_node(node, needle, {kept, open}) do
    if String.contains?(fold(node.name), needle) do
      {kept ++ [node], open}
    else
      case filter_level(node.children, needle) do
        {[], _} -> {kept, open}
        {children, below} -> {kept ++ [%{node | children: children}], [node.id | open] ++ below}
      end
    end
  end

  defp fold(text) when is_binary(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.trim()
  end

  defp fold(_text), do: ""

  @doc "Every id in the tree whose row is one of `types` (`:all` for every row)."
  @spec ids_of([tree_node()], [atom()] | :all) :: [String.t()]
  def ids_of(tree, types \\ :all) do
    Enum.flat_map(tree, fn node ->
      own = if of_type?(node, types), do: [node.id], else: []
      own ++ ids_of(node.children, types)
    end)
  end
end
