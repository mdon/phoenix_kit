defmodule PhoenixKit.Utils.TreeTest do
  @moduledoc """
  `PhoenixKit.Utils.Tree`: building a nested tree from a flat,
  parent-linked list, and the operations a picker runs over it.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.Tree

  defp rec(uuid, parent, name), do: %{uuid: uuid, parent_uuid: parent, name: name}

  # a
  # ├── b
  # │   └── c
  # └── d
  # e
  defp tree do
    Tree.from_flat(
      [
        rec("a", nil, "Kitchen"),
        rec("b", "a", "Doors"),
        rec("c", "b", "Hinges"),
        rec("d", "a", "Drawers"),
        rec("e", nil, "Bathroom")
      ],
      node: &%{name: &1.name, type: if(&1.parent_uuid, do: :child, else: :top)}
    )
  end

  describe "from_flat/2" do
    test "nests by parent, keeping the list's sibling order" do
      assert [%{id: "a", name: "Kitchen", type: :top, children: [b, d]}, %{id: "e"}] = tree()
      assert %{id: "b", children: [%{id: "c", children: []}]} = b
      assert %{id: "d", children: []} = d
    end

    test "a record whose parent is missing is a root; a cycle cannot loop" do
      tree =
        Tree.from_flat([
          rec("orphan", "trashed", "Orphan"),
          rec("x", "y", "X"),
          rec("y", "x", "Y")
        ])

      assert [%{id: "orphan", children: []}] = tree
    end
  end

  test "root/3 is a no-parent row over the tree" do
    assert %{id: "root", type: :root, name: "Top level", hint: "none", children: [_, _]} =
             Tree.root("Top level", tree(), hint: "none")
  end

  test "prune/2 drops rows and everything under them" do
    assert [%{id: "a", children: [%{id: "d"}]}, %{id: "e"}] = Tree.prune(tree(), ["b"])
    assert Tree.prune(tree(), []) == tree()
  end

  test "find/2, member?/3 and path/3" do
    assert %{id: "c", name: "Hinges"} = Tree.find(tree(), "c")
    assert Tree.find(tree(), "zzz") == nil
    assert Tree.find(tree(), nil) == nil

    assert Tree.member?(tree(), "c")
    assert Tree.member?(tree(), "c", [:child])
    refute Tree.member?(tree(), "c", [:top])
    refute Tree.member?(tree(), "zzz")

    assert Tree.path(tree(), "c") == ["Kitchen", "Doors", "Hinges"]
    assert Tree.path(tree(), "c", [:top]) == ["Doors", "Hinges"]
    assert Tree.path(tree(), "zzz") == []
  end

  test "ancestor_ids/2 is top first, without the row itself" do
    assert Tree.ancestor_ids(tree(), "c") == ["a", "b"]
    assert Tree.ancestor_ids(tree(), "a") == []
    assert Tree.ancestor_ids(tree(), nil) == []
  end

  describe "filter/2" do
    test "keeps matches whole and the rows above them, opened" do
      {shown, open} = Tree.filter(tree(), "hinge")

      assert [%{id: "a", children: [%{id: "b", children: [%{id: "c"}]}]}] = shown
      assert Enum.sort(open) == ["a", "b"]
    end

    test "a matching parent keeps its whole subtree, closed; accents and case are ignored" do
      tree = Tree.from_flat([rec("k", nil, "Käsitöö"), rec("l", "k", "Lõng")])

      assert {[%{id: "k", children: [%{id: "l"}]}], []} = Tree.filter(tree, "KASITOO")
    end

    test "a blank query returns the tree and opens nothing" do
      assert Tree.filter(tree(), "  ") == {tree(), []}
    end
  end

  test "ids_of/2 and map_nodes/2" do
    assert Tree.ids_of(tree()) == ["a", "b", "c", "d", "e"]
    assert Tree.ids_of(tree(), [:top]) == ["a", "e"]

    assert [%{icon: "x", children: [%{icon: "x"} | _]} | _] =
             Tree.map_nodes(tree(), &Map.put(&1, :icon, "x"))
  end
end
