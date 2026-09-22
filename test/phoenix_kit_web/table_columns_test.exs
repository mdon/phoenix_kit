defmodule PhoenixKitWeb.TableColumnsTest do
  @moduledoc """
  The column rules every admin table shares: what a stored choice shows,
  and how the modal's edits change it.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.TableColumns

  defp spec(extra \\ %{}) do
    Map.merge(
      %{
        key: "test",
        columns: for(id <- ~w(a b c d), do: %{id: id, label: String.upcase(id)}),
        defaults: ~w(a b)
      },
      extra
    )
  end

  describe "resolve/2" do
    test "no choice shows the defaults, an empty choice shows nothing" do
      assert TableColumns.resolve(nil, spec()) == ~w(a b)
      assert TableColumns.resolve("garbage", spec()) == ~w(a b)
      assert TableColumns.resolve([], spec()) == []
    end

    test "a choice keeps its order and skips ids no longer offered" do
      assert TableColumns.resolve(~w(c gone a c), spec()) == ~w(c a)
    end

    test "a choice with nothing left shows the default" do
      assert TableColumns.resolve(~w(gone also_gone), spec()) == ~w(a b)
    end

    test "an empty site default is a choice too: no optional columns" do
      assert TableColumns.resolve(nil, spec(%{site_default: fn -> [] end})) == []
    end

    test "a choice or site default below the spec's minimum is not used" do
      keep_one = %{min: 1}
      assert TableColumns.resolve([], spec(keep_one)) == ~w(a b)

      assert TableColumns.resolve(nil, spec(Map.put(keep_one, :site_default, fn -> [] end))) ==
               ~w(a b)

      assert TableColumns.resolve(~w(c), spec(keep_one)) == ~w(c)
    end

    test "the site's default wins over the spec's, when it still names a column" do
      assert TableColumns.resolve(nil, spec(%{site_default: fn -> ~w(d c) end})) == ~w(d c)
      assert TableColumns.resolve(nil, spec(%{site_default: fn -> ~w(gone) end})) == ~w(a b)
      assert TableColumns.resolve(nil, spec(%{site_default: fn -> nil end})) == ~w(a b)
    end

    test "without defaults, every column" do
      assert TableColumns.resolve(nil, Map.delete(spec(), :defaults)) == ~w(a b c d)
    end
  end

  describe "edits" do
    test "add appends an offered column once" do
      assert TableColumns.add(~w(a), "c", spec()) == ~w(a c)
      assert TableColumns.add(~w(a c), "c", spec()) == ~w(a c)
      assert TableColumns.add(~w(a), "forged", spec()) == ~w(a)
      assert TableColumns.add(~w(a), nil, spec()) == ~w(a)
    end

    test "remove keeps the spec's minimum" do
      assert TableColumns.remove(~w(a b), "a", spec()) == ~w(b)
      assert TableColumns.remove(~w(a), "a", spec()) == []
      assert TableColumns.remove(~w(a), "a", spec(%{min: 1})) == ~w(a)
      assert TableColumns.remove(~w(a), "c", spec()) == ~w(a)
    end

    test "reorder can reorder but never drop or add" do
      assert TableColumns.reorder(~w(a b c), ~w(c a b), spec()) == ~w(c a b)
      assert TableColumns.reorder(~w(a b c), ~w(c), spec()) == ~w(c a b)
      assert TableColumns.reorder(~w(a b), ~w(d b a b), spec()) == ~w(b a)
      assert TableColumns.reorder(~w(a b), "garbage", spec()) == ~w(a b)
    end
  end
end
