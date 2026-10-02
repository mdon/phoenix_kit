defmodule PhoenixKitWeb.Live.BucketFormTest do
  @moduledoc """
  The storage bucket form: a cloud bucket takes its keys from an
  `object_storage` connection (there are no key fields), a bucket saved before
  that keeps working and offers to move its keys, and no stored secret ever
  reaches the page.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.BucketCredentials
  alias PhoenixKit.Modules.Storage.Providers.S3
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @new_path Routes.path("/admin/settings/media/buckets/new")

  setup %{conn: conn} do
    original = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-bucket-form")

    on_exit(fn ->
      if original,
        do: Application.put_env(:phoenix_kit, :secret_key_base, original),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)
    end)

    {user, _token} = create_admin_user()

    # The auto-grant of the system integrations key runs at boot, not in tests.
    admin_role = Roles.get_role_by_name("Admin")
    {:ok, _} = Permissions.grant_permission(admin_role.uuid, "integrations_system")

    %{conn: log_in_user(conn, user)}
  end

  defp connection(name, attrs \\ %{}) do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("object_storage", name)

    {:ok, _} =
      Integrations.save_setup(
        uuid,
        Map.merge(%{"access_key" => "AKIA#{name}", "secret_key" => "secret-#{name}"}, attrs)
      )

    uuid
  end

  defp legacy_bucket(attrs \\ %{}) do
    {:ok, bucket} =
      Storage.create_bucket(
        Map.merge(
          %{
            name: "Legacy",
            provider: "r2",
            bucket_name: "media",
            region: "auto",
            endpoint: "https://acct.r2.cloudflarestorage.com",
            access_key_id: "AKIALEGACY",
            secret_access_key: "legacy-secret-value"
          },
          attrs
        )
      )

    bucket
  end

  describe "a new cloud bucket" do
    test "has no key fields, but a connection picker and the fields that were missing", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @new_path)

      html = render_change(view, "validate", %{"bucket" => %{"provider" => "r2"}})

      assert html =~ ~s(name="bucket[integration_uuid]")
      assert html =~ ~s(name="bucket[cdn_url]")
      assert html =~ ~s(name="bucket[max_size_mb]")
      refute html =~ ~s(name="bucket[access_key_id]")
      refute html =~ ~s(name="bucket[secret_access_key]")
    end

    test "cannot be saved until a connection is picked, and never needs a passing test", %{
      conn: conn
    } do
      uuid = connection("acct")
      {:ok, view, _html} = live(conn, @new_path)

      params = %{
        "name" => "R2 media",
        "provider" => "r2",
        "bucket_name" => "media",
        "endpoint" => "https://acct.r2.cloudflarestorage.com"
      }

      html = render_change(view, "validate", %{"bucket" => params})
      assert html =~ ~r/<button[^>]*type="submit"[^>]*disabled/

      html =
        render_change(view, "validate", %{"bucket" => Map.put(params, "integration_uuid", uuid)})

      refute html =~ ~r/<button[^>]*type="submit"[^>]*disabled/

      view |> form("#bucket-form") |> render_submit()

      assert %{integration_uuid: ^uuid, access_key_id: nil, secret_access_key: nil} =
               Storage.get_bucket_by_name("R2 media")
    end

    test "picking a connection fills a blank region and endpoint from it", %{conn: conn} do
      uuid =
        connection("acct", %{
          "region" => "eu-central-1",
          "endpoint" => "s3.eu-central-003.backblazeb2.com"
        })

      {:ok, view, _html} = live(conn, @new_path)

      render_change(view, "validate", %{"bucket" => %{"provider" => "b2"}})

      html =
        render_change(view, "validate", %{
          "bucket" => %{"provider" => "b2", "integration_uuid" => uuid}
        })

      assert html =~ "s3.eu-central-003.backblazeb2.com"
    end

    test "picking a connection brings its provider, and the picker names its service", %{
      conn: conn
    } do
      uuid =
        connection("tig", %{"service" => "tigris", "endpoint" => "t3.storage.dev"})

      {:ok, view, _html} = live(conn, @new_path)

      html = render_change(view, "validate", %{"bucket" => %{"provider" => "s3"}})
      assert html =~ "tig — Tigris"

      html =
        render_change(view, "validate", %{
          "bucket" => %{"provider" => "s3", "integration_uuid" => uuid}
        })

      assert html =~ ~s(<option selected="" value="tigris">)
      assert html =~ "t3.storage.dev"
    end

    test "a connection added elsewhere appears in the picker without a reload", %{conn: conn} do
      {:ok, view, _html} = live(conn, @new_path)
      render_change(view, "validate", %{"bucket" => %{"provider" => "s3"}})

      refute render(view) =~ "Brand new connection"

      connection("Brand new connection")

      assert render(view) =~ "Brand new connection"
    end
  end

  describe "editing a bucket that still carries its own keys" do
    test "the page never contains the stored secret, encrypted or not", %{conn: conn} do
      bucket = legacy_bucket()

      {:ok, _view, html} =
        live(conn, Routes.path("/admin/settings/media/buckets/#{bucket.uuid}/edit"))

      refute html =~ "legacy-secret-value"
      refute html =~ Storage.get_bucket(bucket.uuid).secret_access_key
      assert html =~ "keys saved on the bucket itself"
      assert html =~ "AKIALEGACY"
    end

    test "can be saved as it is, without a connection", %{conn: conn} do
      bucket = legacy_bucket()

      {:ok, view, html} =
        live(conn, Routes.path("/admin/settings/media/buckets/#{bucket.uuid}/edit"))

      refute html =~ ~r/<button[^>]*type="submit"[^>]*disabled/

      view |> form("#bucket-form", %{"bucket" => %{"priority" => "3"}}) |> render_submit()

      assert %{priority: 3, access_key_id: "AKIALEGACY", integration_uuid: nil} =
               Storage.get_bucket(bucket.uuid)
    end

    test "moves its keys into an integration and keeps working", %{conn: conn} do
      bucket = legacy_bucket()

      {:ok, view, _html} =
        live(conn, Routes.path("/admin/settings/media/buckets/#{bucket.uuid}/edit"))

      html = render_click(view, "move_credentials", %{})

      refute html =~ "keys saved on the bucket itself"

      moved = Storage.get_bucket(bucket.uuid)
      refute BucketCredentials.legacy?(moved)
      assert S3.resolve_credentials(moved) == {"AKIALEGACY", "legacy-secret-value"}
    end

    test "picking a connection replaces the bucket's own keys on save", %{conn: conn} do
      bucket = legacy_bucket()
      uuid = connection("acct")

      {:ok, view, _html} =
        live(conn, Routes.path("/admin/settings/media/buckets/#{bucket.uuid}/edit"))

      view
      |> form("#bucket-form", %{"bucket" => %{"integration_uuid" => uuid}})
      |> render_submit()

      assert %{integration_uuid: ^uuid, access_key_id: nil, secret_access_key: nil} =
               Storage.get_bucket(bucket.uuid)
    end
  end

  test "an unknown bucket goes back to the list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, Routes.path("/admin/settings/media/buckets/#{UUIDv7.generate()}/edit"))

    assert to == Routes.path("/admin/settings/media")
  end

  describe "the bucket list" do
    test "flags a bucket that carries its own keys and moves them all at once", %{conn: conn} do
      bucket = legacy_bucket()

      {:ok, view, html} = live(conn, Routes.path("/admin/settings/media"))

      assert html =~ "uses keys saved on the bucket itself"
      assert html =~ "Keys on bucket"

      html = render_click(view, "move_all_credentials", %{})

      refute html =~ "uses keys saved on the bucket itself"
      refute BucketCredentials.legacy?(Storage.get_bucket(bucket.uuid))
    end

    test "a Tigris bucket is shown with its bucket and endpoint, not as unknown", %{conn: conn} do
      {:ok, _} =
        Storage.create_bucket(%{
          name: "Tigris bucket",
          provider: "tigris",
          bucket_name: "photos",
          endpoint: "fly.storage.tigris.dev",
          access_key_id: "AKIA",
          secret_access_key: "s"
        })

      {:ok, _view, html} = live(conn, Routes.path("/admin/settings/media"))

      refute html =~ "unknown configuration"
      assert html =~ "tigris:photos"
    end
  end

  describe "removing a connection a bucket uses" do
    test "both Integrations pages say so before it stops working", %{conn: conn} do
      uuid = connection("shared")

      {:ok, _} =
        Storage.create_bucket(%{
          name: "Uses it",
          provider: "s3",
          bucket_name: "b",
          integration_uuid: uuid
        })

      assert %{^uuid => 1} = Storage.bucket_counts_by_connection()

      {:ok, _view, html} = live(conn, Routes.path("/admin/settings/integrations"))
      assert html =~ "1 storage bucket uses this connection"

      {:ok, _view, html} = live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))
      assert html =~ "1 storage bucket uses this connection"
    end

    test "a connection nothing uses keeps the general warning", %{conn: conn} do
      connection("lonely")

      {:ok, _view, html} = live(conn, Routes.path("/admin/settings/integrations"))

      refute html =~ "storage bucket uses this connection"
      assert html =~ "may be in use by other parts of the system"
    end
  end

  test "the new-integration page opens on the provider named in ?provider=", %{conn: conn} do
    {:ok, _view, html} =
      live(conn, Routes.path("/admin/settings/integrations/new?provider=object_storage"))

    assert html =~ "Object Storage"
    assert html =~ ~s(name="name")

    # Something that is not a system provider falls back to the picker.
    {:ok, _view, html} =
      live(conn, Routes.path("/admin/settings/integrations/new?provider=nope"))

    refute html =~ ~s(name="access_key")
  end
end
