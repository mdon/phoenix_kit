defmodule PhoenixKitWeb.Live.Settings.ApiScopesTest do
  @moduledoc """
  Settings -> API: editing the scopes of a key.

  The dialog offers the scopes the key's owner could use now and saves them with
  `PhoenixKit.API.Keys.update_scopes/3`. The key comes from the server (the
  uuid stored when the dialog was opened, found again in the person's own key
  list), never from the submitted params, and every scope is checked again.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Activity
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Cache
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.ServiceUsers
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.RolePermission
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/api")

  setup %{conn: conn} do
    KeyTestSupport.register_fake_module!()
    KeyTestSupport.start_key_cache!()

    {admin, _token} = create_admin_user()
    role = Roles.get_role_by_name("Admin")

    for key <- ["api", "media", "media.manage"],
        do: {:ok, _} = Permissions.grant_permission(role.uuid, key)

    scope = KeyTestSupport.scope_of(admin)

    {key, token} =
      KeyTestSupport.create_key!(admin, scope, %{
        name: "Editable",
        scopes: [KeyTestSupport.read_scope()]
      })

    %{
      conn: log_in_user(conn, admin),
      admin: admin,
      role: role,
      scope: scope,
      key: key,
      token: token
    }
  end

  defp request_edit(view, key) do
    view
    |> element(~s(#api-key-menu-#{key.uuid} button[phx-click="request_edit_scopes"]))
    |> render_click()
  end

  defp scope_box(scope),
    do: ~s(#edit-key-scopes-form input[name="key_scopes[scopes][]"][value="#{scope}"])

  defp save_scopes(view, scopes) do
    view
    |> form("#edit-key-scopes-form", %{"key_scopes" => %{"scopes" => scopes}})
    |> render_submit()
  end

  # The page's scope is captured at mount; a plain delete sends no PubSub message,
  # so the page does not hear of it: the window the server-side re-check is for.
  defp drop_api_silently! do
    role = Roles.get_role_by_name("Admin")

    {1, _} =
      Repo.delete_all(
        from(rp in RolePermission, where: rp.role_uuid == ^role.uuid and rp.module_key == "api")
      )

    :ok
  end

  test "the dialog offers the scopes the owner could use, the key's own ones checked", %{
    conn: conn,
    key: key
  } do
    read = KeyTestSupport.read_scope()
    write = KeyTestSupport.write_scope()
    {:ok, view, _html} = live(conn, @path)

    request_edit(view, key)

    assert has_element?(view, "#edit-key-scopes-modal")
    assert has_element?(view, scope_box(read) <> "[checked]")
    assert has_element?(view, scope_box(write))
    refute has_element?(view, scope_box(write) <> "[checked]")
  end

  test "the dialog does not offer a scope the person editing no longer holds", %{
    conn: conn,
    admin: admin,
    role: role,
    scope: scope
  } do
    read = KeyTestSupport.read_scope()
    write = KeyTestSupport.write_scope()

    {svc_role, _} = KeyTestSupport.role_with(["media", "media.manage"])
    {:ok, svc} = ServiceUsers.create(scope, %{roles: [svc_role.name]})
    {key, _token} = KeyTestSupport.create_key!(svc, scope, %{name: "Service", scopes: [read]})

    # The Admin keeps `api` and loses what the service user holds.
    :ok = Permissions.revoke_permission(role.uuid, "media.manage")
    refute Scope.can?(KeyTestSupport.scope_of(admin), "media.manage")

    {:ok, view, _html} = live(conn, @path)
    request_edit(view, key)

    assert has_element?(view, scope_box(read) <> "[checked]")
    refute has_element?(view, scope_box(write))

    html =
      render_submit(view, "save_key_scopes", %{
        "key_scopes" => %{"present" => "1", "scopes" => [read, write]}
      })

    assert html =~ "not available to that owner"
    assert Keys.get_key(key.uuid).scopes == [read]
  end

  test "saving changes the scopes at once, for a cached key too, and is recorded", %{
    conn: conn,
    admin: admin,
    key: key,
    token: token
  } do
    read = KeyTestSupport.read_scope()
    write = KeyTestSupport.write_scope()

    # Warm the key cache, and prove the row is in it: the fetcher must not run.
    assert {:ok, actor} = Keys.verify(token, nil)
    assert actor.scopes == [read]
    assert %{} = Cache.fetch(key.prefix, fn -> flunk("the key row is not cached") end)

    {:ok, view, _html} = live(conn, @path)
    request_edit(view, key)
    save_scopes(view, [read, write])

    refute has_element?(view, "#edit-key-scopes-modal")
    assert Enum.sort(Keys.get_key(key.uuid).scopes) == Enum.sort([read, write])
    assert {:ok, actor} = Keys.verify(token, nil)
    assert Enum.sort(actor.scopes) == Enum.sort([read, write])

    [entry] = Activity.list(action: "api.key_scopes_updated", actor_uuid: admin.uuid).entries
    assert entry.metadata["from"] == [read]
    assert Enum.sort(entry.metadata["to"]) == Enum.sort([read, write])
  end

  test "a scope the owner could not use is refused and changes nothing", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, @path)
    request_edit(view, key)

    html =
      render_submit(view, "save_key_scopes", %{
        "key_scopes" => %{"present" => "1", "scopes" => ["catalogue.products:delete"]}
      })

    assert html =~ "not available to that owner"
    assert has_element?(view, "#edit-key-scopes-errors")
    assert Keys.get_key(key.uuid).scopes == [KeyTestSupport.read_scope()]
    assert Activity.list(action: "api.key_scopes_updated").entries == []
  end

  test "nothing checked leaves a key that can only read its identity", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, @path)
    request_edit(view, key)

    render_submit(view, "save_key_scopes", %{"key_scopes" => %{"present" => "1"}})

    assert Keys.get_key(key.uuid).scopes == []
  end

  test "a key made by someone else cannot be edited by a forged event", %{conn: conn} do
    read = KeyTestSupport.read_scope()
    {other, _token} = create_admin_user()
    {theirs, _their_token} = KeyTestSupport.create_key!(other, KeyTestSupport.scope_of(other))
    {:ok, view, _html} = live(conn, @path)

    html = render_click(view, "request_edit_scopes", %{"uuid" => theirs.uuid})
    assert html =~ "That key was not found."

    # A save with no dialog of its own does nothing either.
    html =
      render_submit(view, "save_key_scopes", %{
        "key_scopes" => %{"present" => "1", "scopes" => [KeyTestSupport.write_scope()]}
      })

    assert html =~ "That key was not found."
    assert Keys.get_key(theirs.uuid).scopes == [read]
    assert Activity.list(action: "api.key_scopes_updated").entries == []
  end

  test "the Owner may edit a key another person made, within what its owner may use", %{
    conn: conn,
    key: key
  } do
    read = KeyTestSupport.read_scope()
    write = KeyTestSupport.write_scope()
    {:ok, view, _html} = live(log_in_user(conn, KeyTestSupport.owner_user()), @path)

    request_edit(view, key)
    save_scopes(view, [read, write])

    assert Enum.sort(Keys.get_key(key.uuid).scopes) == Enum.sort([read, write])
  end

  test "a revoked key has no scopes to edit", %{conn: conn, key: key} do
    {:ok, _} = Keys.revoke(key, nil)
    {:ok, view, _html} = live(conn, @path)

    refute has_element?(view, "#api-key-menu-#{key.uuid}")
    html = render_click(view, "request_edit_scopes", %{"uuid" => key.uuid})

    assert html =~ "That key was not found."
    assert Keys.get_key(key.uuid).scopes == [KeyTestSupport.read_scope()]
  end

  test "cancelling leaves the key alone", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, @path)
    request_edit(view, key)

    view
    |> element(~s(#edit-key-scopes-modal button[phx-click="cancel_edit_scopes"]))
    |> render_click()

    html =
      render_submit(view, "save_key_scopes", %{
        "key_scopes" => %{"present" => "1", "scopes" => [KeyTestSupport.write_scope()]}
      })

    assert html =~ "That key was not found."
    assert Keys.get_key(key.uuid).scopes == [KeyTestSupport.read_scope()]
  end

  test "scopes the owner can no longer use are listed as inactive and stay on the key when it is saved",
       %{conn: conn, admin: admin, scope: scope, role: role} do
    read = KeyTestSupport.read_scope()
    write = KeyTestSupport.write_scope()
    {wide, _token} = KeyTestSupport.create_key!(admin, scope, %{scopes: [read, write]})

    # Before the page is opened, so core's refresh has nothing to evict.
    :ok = Permissions.revoke_permission(role.uuid, "media.manage")
    {:ok, view, _html} = live(conn, @path)

    request_edit(view, wide)
    assert has_element?(view, scope_box(read) <> "[checked]")
    refute has_element?(view, scope_box(write))
    assert has_element?(view, ~s(#edit-key-scopes-inactive li[data-scope="#{write}"]))

    save_scopes(view, [read])
    assert Enum.sort(Keys.get_key(wide.uuid).scopes) == Enum.sort([read, write])
  end

  test "save_key_scopes after the person lost api changes nothing", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, @path)
    request_edit(view, key)

    drop_api_silently!()
    # Not vacuous: the page has not heard of it, its scope still says api.
    assert Scope.can?(:sys.get_state(view.pid).socket.assigns.phoenix_kit_current_scope, "api")

    html = save_scopes(view, [KeyTestSupport.read_scope(), KeyTestSupport.write_scope()])

    assert html =~ "You are not allowed to do that."
    assert Keys.get_key(key.uuid).scopes == [KeyTestSupport.read_scope()]
    assert Activity.list(action: "api.key_scopes_updated").entries == []
  end

  test "events of the wrong shape do not crash the page", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, @path)
    request_edit(view, key)

    assert render_submit(view, "save_key_scopes", %{"key_scopes" => "not a map"}) =~
             "That action is not available."

    assert render_click(view, "request_edit_scopes", %{}) =~ "That action is not available."
    assert has_element?(view, "#api-settings-page")
    assert Keys.get_key(key.uuid).scopes == [KeyTestSupport.read_scope()]
  end
end
