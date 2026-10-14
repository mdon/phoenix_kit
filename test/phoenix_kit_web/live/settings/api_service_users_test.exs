defmodule PhoenixKitWeb.Live.Settings.ApiServiceUsersTest do
  @moduledoc """
  Settings -> API: service users, and keys owned by them.

  A service user is an account for a program. The page offers only the roles the
  person may hand out and only the service users they may use, and the server
  checks both again, so a forged event creates nothing.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.ServiceUsers
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
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
    for key <- ["api", "media"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)

    %{conn: log_in_user(conn, admin), admin: admin, admin_scope: KeyTestSupport.scope_of(admin)}
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

  # A person who holds `api` and `media` through a role of their own, and nothing
  # else: they may hand out only roles that hold no more than that.
  defp operator do
    {user, role} = KeyTestSupport.user_with(["api", "media"])
    {:ok, user} = Auth.admin_confirm_user(user)
    {user, role}
  end

  defp service_user_count, do: Repo.aggregate(from(u in User, where: u.api_only), :count)

  defp open_service_user_form(view) do
    view |> element("#api-new-service-user") |> render_click()
    view
  end

  defp submit_service_user(view, params) do
    view
    |> form("#create-service-user-form", %{"service_user" => params})
    |> render_submit()
  end

  defp make_service_user!(scope, name, roles \\ nil) do
    roles = roles || scope |> ServiceUsers.allowed_roles() |> Enum.take(1) |> Enum.map(& &1.name)
    {:ok, user} = ServiceUsers.create(scope, %{name: name, roles: roles})
    user
  end

  describe "making a service user" do
    test "the form lists the roles the person may hand out", %{conn: conn, admin_scope: scope} do
      {:ok, view, _html} = live(conn, @path)
      open_service_user_form(view)

      for role <- ServiceUsers.allowed_roles(scope) do
        assert has_element?(
                 view,
                 ~s(#create-service-user-form input[name="service_user[roles][]"][value="#{role.name}"])
               )
      end

      refute has_element?(
               view,
               ~s(#create-service-user-form input[name="service_user[roles][]"][value="Owner"])
             )
    end

    test "a service user is made with the chosen role and appears in the table", %{
      conn: conn,
      admin_scope: scope
    } do
      [role | _] = ServiceUsers.allowed_roles(scope)
      before = service_user_count()
      {:ok, view, _html} = live(conn, @path)
      open_service_user_form(view)

      submit_service_user(view, %{"name" => "Stock bot", "roles" => [role.name]})

      assert service_user_count() == before + 1
      assert has_element?(view, "#api-service-users-table", "Stock bot")
      refute has_element?(view, "#create-service-user-modal")
      refute has_element?(view, "#api-service-users-empty")

      [user | _] = Enum.filter(ServiceUsers.list(scope), &(&1.first_name == "Stock bot"))
      assert user.api_only
      assert String.ends_with?(user.email, "@service.invalid")
      assert Roles.user_has_role?(user, role.name)
    end

    test "a service user cannot be made without a role the person may hand out", %{
      conn: conn
    } do
      {operator, _role} = operator()
      before = service_user_count()
      {:ok, view, _html} = live(log_in_user(conn, operator), @path)

      for forged <- ["Owner", "Admin"] do
        html =
          render_submit(view, "create_service_user", %{
            "service_user" => %{"name" => "Escalation", "roles" => [forged]}
          })

        assert html =~ "more rights than you do"
        assert has_element?(view, "#create-service-user-errors")
      end

      assert service_user_count() == before
    end

    test "create_service_user after the person lost api creates nothing", %{
      conn: conn,
      admin_scope: scope
    } do
      [role | _] = ServiceUsers.allowed_roles(scope)
      before = service_user_count()
      {:ok, view, _html} = live(conn, @path)
      open_service_user_form(view)

      drop_api_silently!()

      html = submit_service_user(view, %{"name" => "Too late", "roles" => [role.name]})

      assert html =~ "You are not allowed to do that."
      assert service_user_count() == before
    end

    test "the form never offers a role that holds more than the person does", %{conn: conn} do
      {operator, _role} = operator()
      {:ok, view, _html} = live(log_in_user(conn, operator), @path)
      open_service_user_form(view)

      refute has_element?(
               view,
               ~s(#create-service-user-form input[name="service_user[roles][]"][value="Admin"])
             )
    end
  end

  describe "who sees which service users" do
    test "a person sees the service users they made, not another person's", %{
      conn: conn,
      admin_scope: scope
    } do
      mine = make_service_user!(scope, "Mine")
      {other, _role} = operator()
      theirs = make_service_user!(KeyTestSupport.scope_of(other), "Theirs")

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#api-service-user-#{mine.uuid}")
      refute has_element?(view, "#api-service-user-#{theirs.uuid}")
    end

    test "the Owner sees every service user", %{conn: conn, admin_scope: scope} do
      mine = make_service_user!(scope, "Mine")

      {:ok, view, _html} = live(log_in_user(conn, KeyTestSupport.owner_user()), @path)

      assert has_element?(view, "#api-service-user-#{mine.uuid}")
    end
  end

  describe "keys owned by a service user" do
    test "the key form offers the service user as an owner and the key is made for it", %{
      conn: conn,
      admin_scope: scope
    } do
      bot = make_service_user!(scope, "Bot")
      {:ok, view, _html} = live(conn, @path)

      view
      |> element(
        ~s(#api-service-user-menu-#{bot.uuid} button[phx-click="open_create_key"][phx-value-owner="#{bot.uuid}"])
      )
      |> render_click()

      assert has_element?(view, ~s(#api-key-owner option[value="#{bot.uuid}"][selected]))

      view
      |> form("#create-api-key-form", %{"key" => %{"name" => "Bot key", "owner" => bot.uuid}})
      |> render_submit()

      assert has_element?(view, "#new-api-token")
      [key] = Enum.filter(Keys.list_keys(scope), &(&1.name == "Bot key"))
      assert key.user_uuid == bot.uuid
      assert has_element?(view, "#api-key-#{key.uuid}", "Bot")
    end

    test "the scopes offered follow the chosen owner's rights", %{
      conn: conn,
      admin_scope: scope
    } do
      {media_role, _} = KeyTestSupport.role_with(["media"])
      {bare_role, _} = KeyTestSupport.role_with([])
      with_media = make_service_user!(scope, "Reader", [media_role.name])
      without = make_service_user!(scope, "Nothing", [bare_role.name])
      read = KeyTestSupport.read_scope()

      assert read in Keys.allowed_scopes_for(with_media)
      refute read in Keys.allowed_scopes_for(without)

      {:ok, view, _html} = live(conn, @path)
      view |> element("#api-new-key") |> render_click()
      read_box = ~s(#create-api-key-form input[name="key[scopes][]"][value="#{read}"])

      view
      |> form("#create-api-key-form", %{"key" => %{"owner" => with_media.uuid}})
      |> render_change()

      assert has_element?(view, read_box)

      view
      |> form("#create-api-key-form", %{"key" => %{"owner" => without.uuid}})
      |> render_change()

      refute has_element?(view, read_box)
    end

    test "a service user another person made cannot be used as an owner", %{
      conn: conn,
      admin: admin
    } do
      {other, _role} = operator()
      theirs = make_service_user!(KeyTestSupport.scope_of(other), "Theirs")
      {:ok, view, _html} = live(conn, @path)
      view |> element("#api-new-key") |> render_click()

      html =
        render_submit(view, "create_key", %{
          "key" => %{"name" => "Borrowed", "owner" => theirs.uuid, "scopes" => []}
        })

      assert html =~ "cannot create keys for that owner"
      assert Keys.list_keys(KeyTestSupport.scope_of(admin)) == []
      assert Keys.list_keys(KeyTestSupport.scope_of(other)) == []
    end
  end
end
