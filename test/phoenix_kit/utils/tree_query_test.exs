defmodule PhoenixKit.Utils.TreeQueryTest do
  @moduledoc """
  `PhoenixKit.Utils.TreeQuery` against a real self-referencing table
  (Storage folders): subtrees and ancestors in one recursive query each,
  and a corrupt parent cycle that still ends.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKit.Utils.TreeQuery

  defp folder(name, parent \\ nil),
    do:
      Repo.insert!(%Folder{
        name: "#{name}-#{System.unique_integer([:positive])}",
        parent_uuid: parent
      })

  setup do
    # a ─ b ─ c
    #  └─ d
    a = folder("a")
    b = folder("b", a.uuid)
    c = folder("c", b.uuid)
    d = folder("d", a.uuid)
    %{a: a, b: b, c: c, d: d}
  end

  test "subtree_uuids/3 is the roots and everything below them, each once", ctx do
    assert Enum.sort(TreeQuery.subtree_uuids(Folder, [ctx.a.uuid])) ==
             Enum.sort([ctx.a.uuid, ctx.b.uuid, ctx.c.uuid, ctx.d.uuid])

    assert Enum.sort(TreeQuery.subtree_uuids(Folder, [ctx.b.uuid, ctx.c.uuid])) ==
             Enum.sort([ctx.b.uuid, ctx.c.uuid])

    assert TreeQuery.subtree_uuids(Folder, []) == []
  end

  test "descendant_uuids/3 leaves the row itself out", ctx do
    assert Enum.sort(TreeQuery.descendant_uuids(Folder, ctx.b.uuid)) == [ctx.c.uuid]
    assert TreeQuery.descendant_uuids(Folder, ctx.c.uuid) == []
  end

  test "ancestor_uuids/3 is every row above, up to the top", ctx do
    assert Enum.sort(TreeQuery.ancestor_uuids(Folder, ctx.c.uuid)) ==
             Enum.sort([ctx.a.uuid, ctx.b.uuid])

    assert TreeQuery.ancestor_uuids(Folder, ctx.a.uuid) == []
  end

  test "a parent cycle ends instead of looping", ctx do
    Repo.update_all(from(f in Folder, where: f.uuid == ^ctx.a.uuid),
      set: [parent_uuid: ctx.c.uuid]
    )

    assert length(TreeQuery.subtree_uuids(Folder, [ctx.a.uuid])) == 4

    assert Enum.sort(TreeQuery.ancestor_uuids(Folder, ctx.c.uuid)) ==
             Enum.sort([ctx.a.uuid, ctx.b.uuid])
  end
end
