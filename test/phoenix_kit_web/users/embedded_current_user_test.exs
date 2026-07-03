defmodule PhoenixKitWeb.Users.EmbeddedCurrentUserTest do
  @moduledoc """
  Tests for `PhoenixKitWeb.Users.Auth.assign_embedded_current_user/2` — the
  generic embed-identity reconstruction helper. An embeddable feature-module
  LiveView (reference consumer: phoenix_kit_projects) mounts off-router via
  `live_render/3`, skips the auth `on_mount` hook, and recovers the current
  user/scope from a host-supplied `session["current_user_uuid"]`.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Users.Auth, as: WebAuth

  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
  end

  defp register!(opts \\ []) do
    {:ok, user} =
      Auth.register_user(%{
        email: "embed-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    if Keyword.get(opts, :active, true) do
      user
    else
      user |> Ecto.Changeset.change(is_active: false) |> Repo.update!()
    end
  end

  test "assigns the user + scope for an active current_user_uuid" do
    user = register!()

    socket = WebAuth.assign_embedded_current_user(socket(), %{"current_user_uuid" => user.uuid})

    assert socket.assigns.phoenix_kit_current_user.uuid == user.uuid
    assert socket.assigns.phoenix_kit_current_scope.user.uuid == user.uuid
  end

  test "absent current_user_uuid degrades to an anonymous scope" do
    socket = WebAuth.assign_embedded_current_user(socket(), %{})

    assert is_nil(socket.assigns.phoenix_kit_current_user)
    assert %Scope{user: nil} = socket.assigns.phoenix_kit_current_scope
  end

  test "unknown current_user_uuid degrades to anonymous (no crash)" do
    socket =
      WebAuth.assign_embedded_current_user(socket(), %{
        "current_user_uuid" => Ecto.UUID.generate()
      })

    assert is_nil(socket.assigns.phoenix_kit_current_user)
    assert %Scope{user: nil} = socket.assigns.phoenix_kit_current_scope
  end

  test "inactive user degrades to anonymous (ensure_active_user)" do
    user = register!(active: false)

    socket = WebAuth.assign_embedded_current_user(socket(), %{"current_user_uuid" => user.uuid})

    assert is_nil(socket.assigns.phoenix_kit_current_user)
    assert %Scope{user: nil} = socket.assigns.phoenix_kit_current_scope
  end

  test "does not clobber an already-present scope (router mount)" do
    existing = Scope.for_user(nil)
    socket = socket(%{phoenix_kit_current_scope: existing})

    result =
      WebAuth.assign_embedded_current_user(socket, %{
        "current_user_uuid" => Ecto.UUID.generate()
      })

    assert result.assigns.phoenix_kit_current_scope == existing
    refute Map.has_key?(result.assigns, :phoenix_kit_current_user)
  end
end
