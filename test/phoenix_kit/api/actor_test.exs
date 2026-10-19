defmodule PhoenixKit.API.ActorTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.API.Actor

  test "the default actor is anonymous with no scopes and no approval flag" do
    actor = %Actor{}

    assert actor.kind == :anonymous
    assert actor.scopes == []
    assert actor.scope == nil
    assert actor.requires_approval == false
    assert actor.key_uuid == nil
    assert actor.user_uuid == nil
    assert actor.cart_token_hash == nil
    assert actor.ip == nil
  end

  test "the struct has exactly the fields of the contract" do
    assert %Actor{} |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
             Enum.sort([
               :kind,
               :key_uuid,
               :key_prefix,
               :user_uuid,
               :scopes,
               :scope,
               :requires_approval,
               :cart_token_hash,
               :ip
             ])
  end

  test "an unknown field is refused, so a typo cannot build an actor" do
    assert_raise KeyError, fn -> struct!(Actor, kind: :key, scopez: ["x"]) end
  end
end
