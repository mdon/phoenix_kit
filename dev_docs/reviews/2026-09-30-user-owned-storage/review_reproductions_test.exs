defmodule PhoenixKit.UserOwnedStorageReviewReproductionsTest do
  @moduledoc """
  Diagnostic reproductions for CODEX_REVIEW.md at 54a2d9205.
  These assertions demonstrate the existing defects; they are not regression
  assertions of the desired behavior. Run explicitly with mix test on this file.
  HTTP requests are intercepted by Req.Test; no internal endpoint is contacted.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Endpoint, Libraries, Library, Manager, Profiles}
  alias PhoenixKit.Modules.Storage.Providers.S3
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Auth, Permissions}
  alias PhoenixKit.Utils.Routes

  @stub __MODULE__.S3
  @moduletag capture_log: true

  setup do
    original_secret = Application.get_env(:phoenix_kit, :secret_key_base)
    original_req = Application.get_env(:ex_aws, :req_opts)
    Application.put_env(:phoenix_kit, :secret_key_base, "review-only-secret")
    Application.put_env(:ex_aws, :req_opts, plug: {Req.Test, @stub})
    Repo.delete_all(PhoenixKit.Modules.Storage.ProfileBucket)
    Manager.invalidate_bucket_cache()
    root = Path.join(System.tmp_dir!(), "pk_codex_review_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      restore_env(:phoenix_kit, :secret_key_base, original_secret)
      restore_env(:ex_aws, :req_opts, original_req)
      Manager.invalidate_bucket_cache()
      File.rm_rf!(root)
    end)

    {:ok, store} = Agent.start_link(fn -> %{} end)
    memory_s3(store)
    %{root: root, store: store}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp user!(permissions \\ []) do
    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{name: "Review #{n}"})
    for key <- permissions, do: Permissions.grant_permission(role.uuid, key)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "review-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, role.name)
    Repo.get!(Auth.User, user.uuid)
  end

  defp owned_bucket!(owner, extra \\ %{}) do
    {:ok, %{uuid: connection}} =
      Integrations.add_connection("object_storage", "review", nil, owner: {:user, owner})

    {:ok, _} =
      Integrations.save_setup(
        connection,
        %{"access_key" => "review-key", "secret_key" => "s"},
        nil,
        owner: {:user, owner}
      )

    {:ok, bucket} =
      Storage.create_owned_bucket(
        owner,
        Map.merge(
          %{
            "name" => "Review #{System.unique_integer([:positive])}",
            "provider" => "s3",
            "bucket_name" => "review-bucket",
            "integration_uuid" => connection,
            "endpoint" => "https://8.8.8.8"
          },
          extra
        )
      )

    bucket
  end

  defp site_bucket!(root) do
    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "Site #{System.unique_integer([:positive])}",
        provider: "local",
        endpoint: root
      })

    bucket
  end

  defp library!(user) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Library{
      name: "Library #{n}",
      slug: "review-#{n}",
      key_prefix: "review-#{n}",
      kind: "user",
      owner_uuid: user.uuid,
      visibility: "private"
    })
  end

  defp memory_s3(store, opts \\ []) do
    Req.Test.stub(@stub, fn conn ->
      [_bucket | key_parts] = conn.path_info
      key = Enum.join(key_parts, "/")

      case conn.method do
        "PUT" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(store, &Map.put(&1, key, body))
          conn |> Plug.Conn.put_resp_header("etag", ~s("etag")) |> Plug.Conn.send_resp(200, "")

        "DELETE" ->
          if Keyword.get(opts, :deny_delete, false) do
            Plug.Conn.send_resp(conn, 403, "Access denied")
          else
            Agent.update(store, &Map.delete(&1, key))
            Plug.Conn.send_resp(conn, 204, "")
          end

        "GET" when key == "" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/xml")
          |> Plug.Conn.send_resp(
            200,
            ~s(<ListBucketResult><Name>b</Name><IsTruncated>false</IsTruncated></ListBucketResult>)
          )

        method when method in ["GET", "HEAD"] ->
          case Agent.get(store, &Map.get(&1, key)) do
            nil ->
              Plug.Conn.send_resp(conn, 404, "")

            body when method == "HEAD" ->
              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(body)))
              |> Plug.Conn.send_resp(200, "")

            body ->
              Plug.Conn.send_resp(conn, 200, body)
          end
      end
    end)
  end

  test "crafted LiveView test_storage selects local and deletes an existing file with own storage disabled",
       %{conn: conn, root: root} do
    {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("storage_user_buckets_enabled", false)
    user = user!(~w(storage storage.create_library))
    File.mkdir_p!(root)
    sentinel = Path.join(root, ".phoenix_kit_test")
    File.write!(sentinel, "existing data")

    {:ok, view, html} = live(log_in_user(conn, user), Routes.path("/profile/settings/media"))
    refute html =~ "My own storage"
    target = with_target(view, "#profile-library-settings")

    render_change(target, "form_change", %{
      "library" => %{"storage" => %{"provider" => "local", "endpoint" => root}}
    })

    render_click(target, "test_storage", %{})
    render_async(view)
    refute File.exists?(sentinel)
  end

  test "Tigris request checks public sslip.io but sends HEAD to a hostname resolving to loopback" do
    assert :ok = Endpoint.check("https://sslip.io", :personal, resolve: true)

    assert {:error, :blocked_address} =
             Endpoint.check("https://127.0.0.1.sslip.io", :personal, resolve: true)

    bucket =
      owned_bucket!(UUIDv7.generate(), %{
        "provider" => "tigris",
        "bucket_name" => "127.0.0.1",
        "endpoint" => "https://sslip.io"
      })

    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      send(test_pid, {:request_host, conn.host})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert S3.file_exists?(bucket, "review.txt")
    assert_receive {:request_host, "127.0.0.1.sslip.io"}
  end

  test "Tigris accepts URL delimiters in the bucket name and signs a loopback URL" do
    bucket =
      owned_bucket!(UUIDv7.generate(), %{
        "provider" => "tigris",
        "bucket_name" => "127.0.0.1:443/x",
        "endpoint" => "https://8.8.8.8"
      })

    assert {:ok, url} = S3.signed_download_url(bucket, "review.txt", [])
    assert URI.parse(url).host == "127.0.0.1"
  end

  test "successful S3 probe destroys an existing object at its fixed key", %{store: store} do
    bucket = owned_bucket!(UUIDv7.generate())
    Agent.update(store, &Map.put(&1, ".phoenix_kit/connection-test", "existing data"))
    assert :ok = S3.test_connection(bucket)
    refute Map.has_key?(Agent.get(store, & &1), ".phoenix_kit/connection-test")
  end

  test "S3 probe passes without GetObject permission" do
    bucket = owned_bucket!(UUIDv7.generate())

    Req.Test.stub(@stub, fn conn ->
      case conn.method do
        "GET" when length(conn.path_info) == 1 ->
          conn
          |> Plug.Conn.put_resp_content_type("application/xml")
          |> Plug.Conn.send_resp(
            200,
            ~s(<ListBucketResult><Name>b</Name><IsTruncated>false</IsTruncated></ListBucketResult>)
          )

        "PUT" ->
          Plug.Conn.send_resp(conn, 200, "")

        "DELETE" ->
          Plug.Conn.send_resp(conn, 204, "")

        _ ->
          Plug.Conn.send_resp(conn, 403, "Access denied")
      end
    end)

    assert :ok = S3.test_connection(bucket)

    assert_raise RuntimeError, ~r/S3 HEAD.*failed/, fn ->
      S3.file_exists?(bucket, "review.txt")
    end
  end

  test "backup upload succeeds solely on an unservable backup when the site is read-only", %{
    root: root,
    store: store
  } do
    user = user!()
    site = site_bucket!(root)
    {:ok, _} = Profiles.put_bucket(Profiles.default_profile(), site.uuid, %{status: "read_only"})
    own = owned_bucket!(user.uuid)
    {:ok, profile} = Profiles.create_user_profile(user.uuid, own, :backup)
    {:ok, library} = Profiles.assign_user_profile(library!(user), profile)
    source = root <> ".txt"
    File.write!(source, "backup only")
    on_exit(fn -> File.rm(source) end)
    checksum = :sha256 |> :crypto.hash("backup only") |> Base.encode16(case: :lower)

    assert {:ok, file} =
             Storage.store_file_in_buckets(
               source,
               "document",
               user.uuid,
               checksum,
               "txt",
               "a.txt",
               library_uuid: library.uuid
             )

    assert [{key, "backup only"}] = Agent.get(store, &Enum.to_list/1)
    assert {:error, :not_found} = Manager.get_file_access(key, file_uuid: file.uuid)
  end

  test "trimming the first four site rows drops the only derived bucket", %{root: root} do
    user = user!()
    default = Profiles.default_profile()

    for n <- 1..5 do
      site = site_bucket!(Path.join(root, to_string(n)))

      {:ok, _} =
        Profiles.put_bucket(default, site.uuid, %{
          stores: if(n == 5, do: "derived", else: "originals"),
          serve_order: n
        })
    end

    assert length(Manager.placement_candidates(Profiles.default_profile(), :derived)) == 1
    {:ok, profile} = Profiles.create_user_profile(user.uuid, owned_bucket!(user.uuid), :backup)
    assert profile.copies_variants == 1
    assert Manager.placement_candidates(profile, :derived) == []
  end

  test "set_library_profile bypasses the final choice with a stale library struct" do
    user = user!()
    stale = library!(user)
    {:ok, profile} = Profiles.create_user_profile(user.uuid, owned_bucket!(user.uuid), :only)
    {:ok, _} = Profiles.assign_user_profile(stale, profile)

    {:ok, site} =
      Profiles.create_profile(%{name: "Site profile #{System.unique_integer([:positive])}"})

    assert {:ok, _} = Profiles.set_library_profile(stale, site.uuid)
    assert Libraries.get_library(stale.uuid).storage_profile_uuid == site.uuid
  end

  test "assign_user_profile moves an existing own-storage library to a second own profile" do
    user = user!()
    {:ok, first} = Profiles.create_user_profile(user.uuid, owned_bucket!(user.uuid), :only)
    {:ok, second} = Profiles.create_user_profile(user.uuid, owned_bucket!(user.uuid), :only)
    {:ok, library} = Profiles.assign_user_profile(library!(user), first)
    assert {:ok, changed} = Profiles.assign_user_profile(library, second)
    assert changed.storage_profile_uuid == second.uuid
  end

  test "generic bucket update accepts a foreign credential connection on an owned bucket" do
    owned = owned_bucket!(UUIDv7.generate())
    {:ok, %{uuid: system}} = Integrations.add_connection("object_storage", "system")

    {:ok, _} =
      Integrations.save_setup(system, %{"access_key" => "system-key", "secret_key" => "s"})

    assert {:ok, updated} = Storage.update_bucket(owned, %{integration_uuid: system})
    assert S3.resolve_credentials(updated) == {nil, nil}
  end

  test "purge reports success and discards the owned bucket after remote deletion fails", %{
    root: root,
    store: store
  } do
    user = user!()
    own = owned_bucket!(user.uuid)
    {:ok, profile} = Profiles.create_user_profile(user.uuid, own, :only)
    {:ok, library} = Profiles.assign_user_profile(library!(user), profile)
    source = root <> ".txt"
    File.write!(source, "private bytes left behind")
    on_exit(fn -> File.rm(source) end)
    checksum = :sha256 |> :crypto.hash("private bytes left behind") |> Base.encode16(case: :lower)

    {:ok, _file} =
      Storage.store_file_in_buckets(source, "document", user.uuid, checksum, "txt", "a.txt",
        library_uuid: library.uuid
      )

    [{key, _}] = Agent.get(store, &Enum.to_list/1)
    memory_s3(store, deny_delete: true)

    {:ok, library} =
      library
      |> Ecto.Changeset.change(trashed_at: DateTime.truncate(DateTime.utc_now(), :second))
      |> Repo.update()

    assert :ok = Libraries.purge_library(library)
    assert Agent.get(store, &Map.has_key?(&1, key))
    assert Storage.get_bucket(own.uuid) == nil
    assert Profiles.get_profile(profile.uuid) == nil
    assert Libraries.get_library(library.uuid) == nil
  end
end
