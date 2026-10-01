defmodule PhoenixKitWeb.Live.Users.OwnStorageUITest do
  @moduledoc """
  The Media tab's creation wizard for a library on the user's own storage
  (V206): shown only to a user who may use it, both modes end to end through
  the component, a failed bucket check creating nothing, the choice shown on
  the library and never changeable, and the admin's view of it (the toggle,
  and a Storage column that names the bucket and never a credential).
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Profiles
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Components.LibrarySettings

  setup do
    original = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-own-storage-ui")

    on_exit(fn ->
      if original,
        do: Application.put_env(:phoenix_kit, :secret_key_base, original),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)
    end)

    {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("storage_user_buckets_enabled", true)

    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{name: "Own storage UI #{n}"})

    for key <- ~w(storage storage.create_library storage.own_storage integrations) do
      {:ok, _} = Permissions.grant_permission(role.uuid, key)
    end

    {:ok, plain} = Roles.create_role(%{name: "Plain UI #{n}"})

    for key <- ~w(storage storage.create_library) do
      {:ok, _} = Permissions.grant_permission(plain.uuid, key)
    end

    {:ok, site} =
      Storage.create_bucket(%{
        name: "ui-site-#{n}",
        provider: "local",
        endpoint: Path.join(System.tmp_dir!(), "pk_own_storage_ui"),
        enabled: true
      })

    %{role: role, plain: plain, site: site}
  end

  defp user!(role) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "own-ui-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, role.name)
    Repo.get!(Auth.User, user.uuid)
  end

  defp scope(user), do: Scope.for_user(Repo.get!(Auth.User, user.uuid))

  defp connection!(user, attrs \\ %{}) do
    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("object_storage", "mine", nil, owner: {:user, user.uuid})

    {:ok, _} =
      Integrations.save_setup(
        uuid,
        Map.merge(%{"access_key" => "AKIA", "secret_key" => "secret-value"}, attrs),
        nil,
        owner: {:user, user.uuid}
      )

    uuid
  end

  # The component mounted the way a LiveView would, with a probe that answers.
  defp mount!(user, probe \\ fn _params -> :ok end) do
    {:ok, socket} =
      LibrarySettings.update(
        %{id: "profile-library-settings", scope: scope(user), probe: probe},
        %Phoenix.LiveView.Socket{}
      )

    socket
  end

  defp form_change(socket, library) do
    {:noreply, socket} =
      LibrarySettings.handle_event("form_change", %{"library" => library}, socket)

    socket
  end

  defp create(socket, library) do
    {:noreply, socket} = LibrarySettings.handle_event("create", %{"library" => library}, socket)
    socket
  end

  defp own(connection, extra \\ %{}) do
    storage =
      Map.merge(
        %{
          "kind" => "own",
          "mode" => "only",
          "integration_uuid" => connection,
          "provider" => "s3",
          "bucket_name" => "my-photos",
          "region" => "eu-central-1"
        },
        extra
      )

    %{"name" => "Photos", "storage" => storage}
  end

  describe "who sees it" do
    test "the choice of storage is on the Media tab for a user who may use their own", %{
      conn: conn,
      role: role
    } do
      user = user!(role)

      {:ok, _view, html} = live(log_in_user(conn, user), Routes.path("/profile/settings/media"))

      assert html =~ "Where its files are kept"
      assert html =~ "My own storage"
    end

    test "a user who may not sees only the plain form", %{conn: conn, plain: plain} do
      user = user!(plain)

      {:ok, _view, html} = live(log_in_user(conn, user), Routes.path("/profile/settings/media"))

      assert html =~ "New library"
      refute html =~ "Where its files are kept"
      refute html =~ "My own storage"
    end

    test "nor when the site has not allowed it", %{conn: conn, role: role} do
      {:ok, _} = Settings.update_boolean_setting("storage_user_buckets_enabled", false)
      user = user!(role)

      {:ok, _view, html} = live(log_in_user(conn, user), Routes.path("/profile/settings/media"))

      refute html =~ "My own storage"
    end
  end

  describe "the form" do
    test "lists the user's own connections only", %{role: role} do
      user = user!(role)
      other = user!(role)
      mine = connection!(user)
      _theirs = connection!(other)

      socket = mount!(user)

      assert [%{uuid: ^mine}] = socket.assigns.connections
    end

    test "a picked connection fills a blank region and endpoint", %{role: role} do
      user = user!(role)

      uuid =
        connection!(user, %{
          "region" => "auto",
          "endpoint" => "https://acct.r2.cloudflarestorage.com"
        })

      socket =
        user
        |> mount!()
        |> form_change(%{
          "name" => "P",
          "storage" => %{"kind" => "own", "integration_uuid" => uuid}
        })

      assert socket.assigns.form["region"] == "auto"
      assert socket.assigns.form["endpoint"] == "https://acct.r2.cloudflarestorage.com"
    end

    test "what the user typed is not overwritten by the connection", %{role: role} do
      user = user!(role)
      uuid = connection!(user, %{"region" => "auto"})

      socket =
        user
        |> mount!()
        |> form_change(%{
          "name" => "P",
          "storage" => %{"kind" => "own", "region" => "eu-west-1", "integration_uuid" => uuid}
        })

      assert socket.assigns.form["region"] == "eu-west-1"
    end
  end

  describe "creating" do
    test "only mode: the library, its bucket and its profile", %{role: role} do
      user = user!(role)
      socket = user |> mount!() |> create(own(connection!(user)))

      assert {:success, message} = socket.assigns.message
      assert message =~ "Photos"

      assert [%{library: library}] = socket.assigns.owned

      assert %{mode: :only, bucket: %{bucket_name: "my-photos"}} =
               socket.assigns.own_storage[to_string(library.uuid)]

      # The form starts over.
      assert socket.assigns.form["kind"] == "site"
    end

    test "backup mode", %{role: role, site: site} do
      user = user!(role)
      socket = user |> mount!() |> create(own(connection!(user), %{"mode" => "backup"}))

      assert [%{library: library}] = socket.assigns.owned
      assert %{mode: :backup} = socket.assigns.own_storage[to_string(library.uuid)]

      profile = Profiles.get_profile(library.storage_profile_uuid)
      assert Enum.any?(profile.buckets, &(to_string(&1.bucket_uuid) == to_string(site.uuid)))
    end

    test "a bucket that fails its check creates nothing and says why", %{role: role} do
      user = user!(role)
      failing = fn _params -> {:error, "The bucket can be read but not written to"} end

      socket = user |> mount!(failing) |> create(own(connection!(user)))

      assert {:error, message} = socket.assigns.message
      assert message =~ "The bucket can be read but not written to"
      assert socket.assigns.owned == []
      assert Storage.list_owned_buckets(user.uuid) == []
    end

    test "bad bucket fields are explained", %{role: role} do
      user = user!(role)

      socket =
        user |> mount!() |> create(own(connection!(user), %{"endpoint" => "https://10.0.0.5"}))

      assert {:error, message} = socket.assigns.message
      assert message =~ "endpoint"
      assert socket.assigns.owned == []
    end

    test "a plain library needs none of it", %{role: role} do
      user = user!(role)
      socket = user |> mount!() |> create(%{"name" => "Plain", "storage" => %{"kind" => "site"}})

      assert {:success, _} = socket.assigns.message
      assert [%{library: %{storage_profile_uuid: nil}}] = socket.assigns.owned
    end

    test "a user who may not use their own storage cannot ask for it", %{plain: plain} do
      user = user!(plain)

      socket = user |> mount!() |> create(own(Ecto.UUID.generate()))

      # Their own-storage fields are ignored: the library is made on the site's storage.
      assert [%{library: %{storage_profile_uuid: nil}}] = socket.assigns.owned
      assert Storage.list_owned_buckets(user.uuid) == []
    end
  end

  describe "the library afterwards" do
    test "says where it keeps its files, and cannot be moved", %{conn: conn, role: role} do
      user = user!(role)
      socket = user |> mount!() |> create(own(connection!(user)))
      [%{library: library}] = socket.assigns.owned

      {:ok, _view, html} = live(log_in_user(conn, user), Routes.path("/profile/settings/media"))

      assert html =~ "Your bucket: my-photos"
      assert html =~ "including the copies in your own bucket"
      assert {:error, :user_storage_locked} = Profiles.set_library_profile(library, nil)
    end
  end

  describe "the admin's view" do
    test "the list names the storage and never a credential", %{role: role} do
      user = user!(role)
      _ = mount!(user) |> create(own(connection!(user, %{"endpoint" => "https://8.8.8.8"})))

      {:ok, admin} = admin_with_storage_settings()

      {:ok, _view, html} =
        live(log_in_user(build_conn(), admin), Routes.path("/admin/settings/media"))

      # The Libraries tab is the one with the user library list.
      html = render_libraries_tab(html, admin)

      assert html =~ "Own S3 bucket"
      refute html =~ "secret-value"
      refute html =~ "AKIA"
    end
  end

  defp admin_with_storage_settings do
    {admin, _token} = create_admin_user()
    {:ok, admin}
  end

  defp render_libraries_tab(_html, admin) do
    {:ok, view, _html} =
      live(log_in_user(build_conn(), admin), Routes.path("/admin/settings/media"))

    render_patch(view, Routes.path("/admin/settings/media?tab=libraries"))
  end

  describe "removing the connection a library's bucket uses" do
    test "both personal pages say so before it stops working", %{conn: conn, role: role} do
      user = user!(role)
      connection = connection!(user)
      _ = user |> mount!() |> create(own(connection))

      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, Routes.path("/profile/settings/integrations"))
      assert html =~ "1 of your libraries keeps its files in a bucket that uses this connection"

      {:ok, _view, html} = live(conn, Routes.path("/profile/settings/integrations/#{connection}"))
      assert html =~ "1 of your libraries keeps its files in a bucket that uses this connection"
    end

    test "a connection nothing uses keeps the plain question", %{conn: conn, role: role} do
      user = user!(role)
      _ = connection!(user)

      {:ok, _view, html} =
        live(log_in_user(conn, user), Routes.path("/profile/settings/integrations"))

      assert html =~ "Remove this connection?"
      refute html =~ "keeps its files in a bucket"
    end
  end

  describe "Object Storage as a personal connection" do
    test "is offered only while the site allows users their own buckets" do
      keys = fn -> Enum.map(Providers.personal_offered(), & &1.key) end

      assert "object_storage" in keys.()

      {:ok, _} = Settings.update_boolean_setting("storage_user_buckets_enabled", false)

      refute "object_storage" in keys.()
      assert "telegram" in keys.()
    end
  end

  test "the new personal connection page opens on the provider named in ?provider=", %{
    conn: conn,
    role: role
  } do
    user = user!(role)

    {:ok, _view, html} =
      live(
        log_in_user(conn, user),
        Routes.path("/profile/settings/integrations/new?provider=object_storage")
      )

    # The form for that provider, not the list of providers to choose from.
    assert html =~ "Object Storage"
    refute html =~ "Telegram"
  end

  test "the profile's tabs stay on the add and edit pages of a personal integration", %{
    conn: conn,
    role: role
  } do
    user = user!(role)
    connection = connection!(user)
    conn = log_in_user(conn, user)

    for path <- [
          "/profile/settings/integrations",
          "/profile/settings/integrations/new",
          "/profile/settings/integrations/#{connection}"
        ] do
      {:ok, _view, html} = live(conn, Routes.path(path))

      assert html =~ "Security", path
      assert html =~ "Sessions", path
      assert html =~ ~s(aria-selected="true") or html =~ "tab-active", path
    end
  end
end
