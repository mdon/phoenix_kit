defmodule PhoenixKit.Integration.Users.RolesPermissionsEditorFlashTest do
  @moduledoc """
  A blocked "edit role permissions" click on the Roles tab must show the
  translated reason, never the bare `{:error, reason}` atom
  `Permissions.can_edit_role_permissions?/2` returns.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    {admin, _token} = create_admin_user()
    {:ok, conn: log_in_user(conn, admin), admin: admin}
  end

  describe "/admin/users/roles" do
    test "clicking the Owner role shows the translated message, not the raw atom", %{
      conn: conn
    } do
      owner = Roles.get_role_by_name("Owner")

      {:ok, view, _html} = live(conn, Routes.path("/admin/users/roles"))

      html =
        render_click(view, "show_permissions_editor", %{"role_uuid" => to_string(owner.uuid)})

      assert html =~ "Owner role always has full access and cannot be modified"
      refute html =~ "owner_immutable"
    end
  end
end
