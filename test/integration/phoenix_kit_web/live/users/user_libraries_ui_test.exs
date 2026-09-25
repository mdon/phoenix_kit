defmodule PhoenixKitWeb.Live.Users.UserLibrariesUITest do
  @moduledoc """
  The pages of user libraries (V203): `/admin/libraries` (own and shared
  libraries, an Owner/Admin opening one with an audit entry), the media
  browser refusing an event that names another library's file, the
  profile's Media tab, and the User libraries card in Settings → Media.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.AuditLog.Entry
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.MediaBrowser

  setup do
    {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)

    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{name: "Library users #{n}"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "storage")
    {:ok, _} = Permissions.grant_permission(role.uuid, "storage.create_library")

    %{role: role}
  end

  defp user!(role \\ nil) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "ul-ui-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    if role, do: {:ok, _} = Roles.assign_role(user, role.name)
    Repo.get!(Auth.User, user.uuid)
  end

  defp scope(user), do: Scope.for_user(Repo.get!(Auth.User, user.uuid))

  defp library!(user, name) do
    {:ok, library} = Libraries.create_user_library(scope(user), %{"name" => name})
    library
  end

  describe "/admin/libraries" do
    test "lists the user's own and shared libraries", %{conn: conn, role: role} do
      owner = user!(role)
      mine = library!(owner, "My Photos")
      other = user!(role)
      shared = library!(other, "Family")
      {:ok, _} = Libraries.add_member(scope(other), shared, owner.email, "viewer")

      {:ok, _view, html} = live(log_in_user(conn, owner), Routes.path("/admin/libraries"))

      assert html =~ "My Photos"
      assert html =~ "Family"
      assert html =~ ~s(href="#{Routes.path("/admin/libraries/#{mine.slug}")}")
      assert html =~ ~s(href="#{Routes.path("/admin/libraries/#{shared.uuid}")}")
    end

    test "opens one's own library by slug; someone else's is not found", %{conn: conn, role: role} do
      owner = user!(role)
      library = library!(owner, "Holiday")

      {:ok, _view, html} =
        live(log_in_user(conn, owner), Routes.path("/admin/libraries/#{library.slug}"))

      assert html =~ "library-browser"

      stranger = user!(role)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(
                 log_in_user(build_conn(), stranger),
                 Routes.path("/admin/libraries/#{library.uuid}")
               )

      assert to == Routes.path("/admin/libraries")
    end

    test "nothing while user libraries are off", %{conn: conn, role: role} do
      user = user!(role)
      {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", false)

      assert {:error, {_kind, %{to: to}}} =
               live(log_in_user(conn, user), Routes.path("/admin/libraries"))

      assert to == Routes.path("/profile/settings")
    end

    test "an Admin sees other users' libraries below their own; a user does not",
         %{conn: conn, role: role} do
      owner = user!(role)
      library = library!(owner, "Someone Elses")
      {admin, _token} = create_admin_user()

      {:ok, _view, html} = live(log_in_user(conn, admin), Routes.path("/admin/libraries"))

      assert html =~ "libraries-others"
      assert html =~ "Someone Elses"
      assert html =~ owner.email
      assert html =~ ~s(href="#{Routes.path("/admin/libraries/#{library.uuid}")}")

      {:ok, _view, html} =
        live(log_in_user(build_conn(), user!(role)), Routes.path("/admin/libraries"))

      refute html =~ "Someone Elses"
    end

    test "an Admin opening a user's library is written to the audit log", %{
      conn: conn,
      role: role
    } do
      owner = user!(role)
      library = library!(owner, "Private")
      {admin, _token} = create_admin_user()

      {:ok, _view, html} =
        live(log_in_user(conn, admin), Routes.path("/admin/libraries/#{library.uuid}"))

      assert html =~ "library-browser"

      assert [entry] =
               Repo.all(
                 from(e in Entry,
                   where:
                     e.action == "storage.library_opened" and e.admin_user_uuid == ^admin.uuid
                 )
               )

      assert entry.target_user_uuid == owner.uuid
      assert entry.metadata["library_uuid"] == library.uuid
    end
  end

  describe "the media browser inside a library" do
    test "an event naming a file of another library is refused", %{role: role} do
      owner = user!(role)
      library = library!(owner, "Guarded")

      {:ok, media_file} =
        Storage.create_file(%{
          original_file_name: "a.png",
          file_name: "a.png",
          file_path: "x/a.png",
          mime_type: "image/png",
          file_type: "image",
          ext: "png",
          file_checksum: Ecto.UUID.generate(),
          user_file_checksum: Ecto.UUID.generate(),
          size: 1,
          status: "active",
          user_uuid: owner.uuid
        })

      assert MediaBrowser.foreign_reference?(%{"file_uuid" => media_file.uuid}, library.uuid)

      assert MediaBrowser.foreign_reference?(
               %{"uuids" => ["not-a-uuid", media_file.uuid]},
               library.uuid
             )

      refute MediaBrowser.foreign_reference?(
               %{"file_uuid" => media_file.uuid},
               media_file.library_uuid
             )

      refute MediaBrowser.foreign_reference?(%{"name" => "x"}, library.uuid)
    end
  end

  describe "the profile's Media tab" do
    test "is offered with storage and user libraries on", %{conn: conn, role: role} do
      user = user!(role)
      {:ok, _view, html} = live(log_in_user(conn, user), Routes.path("/profile/settings"))
      assert html =~ ~s(href="#{Routes.path("/profile/settings/media")}")

      plain = user!()

      {:ok, _view, html} =
        live(log_in_user(build_conn(), plain), Routes.path("/profile/settings"))

      refute html =~ ~s(href="#{Routes.path("/profile/settings/media")}")
    end

    test "creates a library and adds a member", %{conn: conn, role: role} do
      user = user!(role)
      member = user!(role)

      {:ok, view, _html} = live(log_in_user(conn, user), Routes.path("/profile/settings/media"))

      view
      |> form("#profile-library-settings-create", %{library: %{name: "From The Tab"}})
      |> render_submit()

      assert [%{library: library}] = Libraries.list_user_libraries(user.uuid)
      assert library.name == "From The Tab"

      view
      |> element("#library-row-#{library.uuid} button", "Members")
      |> render_click()

      html =
        view
        |> form("#profile-library-settings-add-member-#{library.uuid}", %{
          member: %{email: member.email, role: "contributor"}
        })
        |> render_submit()

      assert html =~ "Member added"
      assert html =~ member.email
      assert Libraries.role(library, member.uuid) == :contributor
    end
  end

  describe "Settings → Media → Libraries" do
    test "turns user libraries off and lists them as metadata", %{conn: conn, role: role} do
      owner = user!(role)
      library!(owner, "Listed For Admins")
      {admin, _token} = create_admin_user()

      {:ok, view, html} = live(log_in_user(conn, admin), Routes.path("/admin/settings/media"))
      assert html =~ "Listed For Admins"
      assert html =~ owner.email

      view
      |> form("#media-libraries-user-settings", %{
        user_libraries: %{enabled: "false", limit: "4", window_hours: "6"}
      })
      |> render_submit()

      refute Libraries.user_libraries_enabled?()
      assert Libraries.user_library_limit() == 4
    end
  end
end
