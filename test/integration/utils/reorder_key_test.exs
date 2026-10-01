defmodule PhoenixKit.Integration.Utils.ReorderKeyTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Utils.Reorder

  # A host-style table keyed by an integer, created per test inside the
  # sandbox transaction.
  defmodule IntRow do
    use Ecto.Schema

    schema "reorder_int_probe" do
      field(:position, :integer)
    end
  end

  setup do
    Repo.query!("CREATE TEMP TABLE reorder_int_probe (id serial PRIMARY KEY, position integer)")
    Repo.query!("INSERT INTO reorder_int_probe (position) VALUES (1), (2), (3)")
    :ok
  end

  defp positions do
    Repo.query!("SELECT id, position FROM reorder_int_probe ORDER BY id").rows
  end

  test "key: :id reorders an integer-keyed table from the strings a hook sends" do
    assert {:ok, 3} = Reorder.reorder(IntRow, ["3", "1", "2"], :position, key: :id, repo: Repo)
    assert positions() == [[1, 2], [2, 3], [3, 1]]
  end

  test "integers are accepted as they are, and junk is filtered" do
    assert {:ok, 2} =
             Reorder.reorder(IntRow, [2, "nope", nil, "1"], :position, key: :id, repo: Repo)

    assert positions() == [[1, 2], [2, 1], [3, 3]]
  end

  test "max_ids caps the payload after dedup" do
    assert {:error, :too_many_uuids} =
             Reorder.reorder(IntRow, ["1", "2", "3"], :position, key: :id, repo: Repo, max_ids: 2)
  end

  test "without key: a non-UUID payload still does nothing" do
    assert {:ok, 0} = Reorder.reorder(IntRow, ["1", "2"], :position, repo: Repo)
  end

  test "a key that is not a field is refused up front, not mid-transaction" do
    assert_raise ArgumentError, ~r/:nope is not a field/, fn ->
      Reorder.reorder(IntRow, ["1", "2"], :position, key: :nope, repo: Repo)
    end
  end
end
