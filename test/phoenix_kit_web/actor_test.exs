defmodule PhoenixKitWeb.ActorTest do
  @moduledoc """
  `PhoenixKitWeb.Actor` reads who is acting the same way for every module:
  the scope first, the bare current user as the fallback.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth.{Scope, User}
  alias PhoenixKitWeb.Actor

  @scoped "019a0000-0000-7000-8000-000000000001"
  @bare "019a0000-0000-7000-8000-000000000002"

  defp scope(uuid, roles \\ []),
    do: %Scope{user: %User{uuid: uuid}, authenticated?: true, cached_roles: roles}

  defp socket(assigns), do: %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}

  test "the scope's user wins over the bare current user" do
    assigns = %{
      phoenix_kit_current_scope: scope(@scoped),
      phoenix_kit_current_user: %User{uuid: @bare}
    }

    assert Actor.uuid(assigns) == @scoped
    assert Actor.uuid(socket(assigns)) == @scoped
    assert Actor.uuid(%Plug.Conn{assigns: assigns}) == @scoped
  end

  test "the bare current user is the fallback — no scope, or an anonymous one" do
    assert Actor.uuid(%{phoenix_kit_current_user: %User{uuid: @bare}}) == @bare

    anonymous = %{
      phoenix_kit_current_scope: Scope.for_user(nil),
      phoenix_kit_current_user: %{uuid: @bare}
    }

    assert Actor.uuid(anonymous) == @bare
  end

  test "nobody signed in is nil, whatever the shape" do
    for source <- [
          %{},
          socket(%{}),
          %Plug.Conn{},
          nil,
          "x",
          %{phoenix_kit_current_user: %{uuid: 1}}
        ] do
      assert Actor.uuid(source) == nil, inspect(source)
    end
  end

  test "a scope is a source on its own — and a fixture user needs only a uuid" do
    assert Actor.uuid(scope(@scoped)) == @scoped
    assert Actor.uuid(Scope.for_user(nil)) == nil

    fixture = %Scope{user: %{uuid: @scoped}, authenticated?: true, cached_roles: ["Owner"]}
    assert Actor.uuid(%{phoenix_kit_current_scope: fixture}) == @scoped
    assert Actor.role(fixture) == "Owner"
  end

  test "opts/1 is the actor option, or nothing to append" do
    assert Actor.opts(%{phoenix_kit_current_scope: scope(@scoped)}) == [actor_uuid: @scoped]
    assert Actor.opts(%{}) == []
  end

  test "role/1 is the active role while acting as one, not an always-on role" do
    scope = %{
      scope(@scoped, ["User", "Editor"])
      | active_role: %{uuid: "019a0000-0000-7000-8000-000000000003", name: "Editor"}
    }

    assert Actor.role(scope) == "Editor"
  end

  test "role/1 is the first cached role, or nil" do
    assert Actor.role(%{phoenix_kit_current_scope: scope(@scoped, ["Admin", "Owner"])}) == "Admin"
    assert Actor.role(socket(%{phoenix_kit_current_scope: scope(@scoped)})) == nil
    assert Actor.role(nil) == nil
  end
end
