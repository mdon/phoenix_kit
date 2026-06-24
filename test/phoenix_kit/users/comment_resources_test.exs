defmodule PhoenixKit.Users.CommentResourcesTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.CommentResources
  alias PhoenixKit.Utils.Routes

  test "resolves a user to its display title + admin detail path" do
    {:ok, user} =
      Auth.register_user(%{email: "moderate-me@example.com", password: "ValidPassword123!"})

    result = CommentResources.resolve_comment_resources([user.uuid])

    assert %{title: "moderate-me@example.com", path: path} = result[user.uuid]
    assert path == Routes.path("/admin/users/view/#{user.uuid}")
    # No avatar configured → no thumbnail key (chip falls back to a badge).
    refute Map.has_key?(result[user.uuid], :thumb_url)
  end

  test "unknown or empty uuid lists resolve to an empty map" do
    assert CommentResources.resolve_comment_resources([Ecto.UUID.generate()]) == %{}
    assert CommentResources.resolve_comment_resources([]) == %{}
  end
end
