defmodule PhoenixKit.Integration.ActivityFilterTest do
  @moduledoc """
  Filtering of `PhoenixKit.Activity.list/1`, focused on `:resource_uuid` —
  added so a feed can be scoped to a single resource. Before it, `list/1`
  honoured `:resource_type` but silently ignored `:resource_uuid`, leaking
  every same-type resource's activity into a per-resource view.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Activity

  defp log!(resource_uuid) do
    {:ok, entry} =
      Activity.log(%{
        action: "thing.created",
        module: "activity_filter_test",
        resource_type: "filter_test_thing",
        resource_uuid: resource_uuid
      })

    entry
  end

  test "list/1 scopes to a single resource_uuid" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    log!(a)
    log!(a)
    log!(b)

    result =
      Activity.list(resource_type: "filter_test_thing", resource_uuid: a)

    assert result.total == 2
    assert Enum.all?(result.entries, &(&1.resource_uuid == a))
    refute Enum.any?(result.entries, &(&1.resource_uuid == b))
  end

  test "count/1 honours resource_uuid too" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    log!(a)
    log!(b)

    assert Activity.count(resource_type: "filter_test_thing", resource_uuid: a) == 1
  end

  test "omitting resource_uuid returns all of the resource_type" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    log!(a)
    log!(b)

    assert Activity.list(resource_type: "filter_test_thing").total == 2
  end
end
