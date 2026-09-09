defmodule PhoenixKit.Integration.Users.UserDeletionConfirmationTest do
  @moduledoc """
  Permanent user deletion: offered only from the user's own page (not the
  Users list row menu), labeled "Permanently Delete", and gated behind a
  confirmation screen that shows real per-user record counts — not a
  generic, always-the-same bullet list — so an admin can tell whether
  there's actually anything to lose before committing to an irreversible
  action.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Users.AdminNote
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  defp unique_email, do: "del_confirm_#{System.unique_integer([:positive])}@example.com"

  defp plain_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)
    Repo.get!(Auth.User, user.uuid)
  end

  defp admin_user do
    user = plain_user()
    Roles.assign_role(user, "Admin")
    Repo.get!(Auth.User, user.uuid)
  end

  defp view_path(user), do: Routes.path("/admin/users/view/#{user.uuid}")

  describe "the Users list" do
    test "no longer offers a delete action from its row menu", %{conn: conn} do
      _target = plain_user()
      conn = log_in_user(conn, admin_user())

      {:ok, _view, html} = live(conn, Routes.path("/admin/users"))

      refute html =~ "request_delete_user"
      refute html =~ ~s(phx-click="delete_user")
    end
  end

  describe "the user's own page" do
    test ~s(offers a button labeled "Permanently Delete", not "Delete"), %{conn: conn} do
      target = plain_user()
      conn = log_in_user(conn, admin_user())

      {:ok, _view, html} = live(conn, view_path(target))

      assert html =~ "Permanently Delete"
    end

    test "the confirmation screen shows real counts for this user, not a generic list", %{
      conn: conn
    } do
      target = plain_user()

      {:ok, _note} =
        %AdminNote{}
        |> AdminNote.changeset(%{
          user_uuid: target.uuid,
          content: "flagged for review",
          author_uuid: target.uuid
        })
        |> Repo.insert()

      conn = log_in_user(conn, admin_user())
      {:ok, view, _html} = live(conn, view_path(target))

      html = render_click(view, "show_delete_modal")

      assert html =~ "Permanently Delete User"
      assert html =~ "Admin notes"
      # This user has exactly one admin note and no OAuth connections — the
      # old modal showed the same six-item bullet list for every user
      # regardless of what was actually there.
      assert html =~ ~r/Admin notes.*?\b1\b/s
      assert html =~ ~r/OAuth connections.*?\b0\b/s
    end

    test "deleting from the confirmation screen still works", %{conn: conn} do
      target = plain_user()
      conn = log_in_user(conn, admin_user())
      {:ok, view, _html} = live(conn, view_path(target))

      render_click(view, "show_delete_modal")
      render_click(view, "delete_user")

      refute Auth.get_user(target.uuid)
    end
  end
end
