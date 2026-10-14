defmodule PhoenixKit.API.KeysAliveTest do
  @moduledoc """
  `Keys.dead_reason/1`: when a key row may no longer be used (the row only; the owner is
  `Keys.active?/1`, tested with real rows in `confirm_test.exs`). A revocation or an
  expiry in the future has not happened yet (a rotation's grace period is a scheduled
  revocation); one at this very second has.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key

  defp at(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  test "a key with no end is alive" do
    assert Keys.dead_reason(%Key{revoked_at: nil, expires_at: nil}) == nil
  end

  test "a revocation in the past: revoked" do
    assert Keys.dead_reason(%Key{revoked_at: at(-5), expires_at: nil}) == :revoked
  end

  test "an expiry in the past: expired" do
    assert Keys.dead_reason(%Key{revoked_at: nil, expires_at: at(-5)}) == :expired
  end

  test "both in the past: revoked wins" do
    assert Keys.dead_reason(%Key{revoked_at: at(-5), expires_at: at(-10)}) == :revoked
  end

  test "an end in the future has not happened yet" do
    assert Keys.dead_reason(%Key{revoked_at: at(3600), expires_at: at(7200)}) == nil
  end

  test "an end at this very second has happened" do
    assert Keys.dead_reason(%Key{revoked_at: at(0)}) == :revoked
    assert Keys.dead_reason(%Key{expires_at: at(0)}) == :expired
  end
end
