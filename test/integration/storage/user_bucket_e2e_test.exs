defmodule PhoenixKit.Modules.Storage.UserBucketE2ETest do
  @moduledoc """
  A file through a user's own bucket, end to end (V206), against an in-memory
  S3 behind `Req.Test` (no socket is opened, so the strict endpoint policy
  stays as it is in production): the library is created after a real
  list/write/delete probe, an upload lands in the user's bucket and nowhere
  else, is read back from it, and is deleted from it with the file.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{FileLocation, Libraries, Manager}
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.Scope

  import Ecto.Query

  @stub __MODULE__.S3

  # The bucket check runs in `Integrations.Probe`'s own process, which Req.Test's
  # per-process stubs do not reach.
  setup {Req.Test, :set_req_test_to_shared}

  setup do
    {:ok, store} = Agent.start_link(fn -> %{} end)

    Req.Test.stub(@stub, fn conn ->
      [_bucket | key_parts] = conn.path_info
      key = Enum.join(key_parts, "/")

      case conn.method do
        "PUT" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(store, &Map.put(&1, key, body))
          conn |> Plug.Conn.put_resp_header("etag", ~s("etag")) |> Plug.Conn.send_resp(200, "")

        "DELETE" ->
          Agent.update(store, &Map.delete(&1, key))
          Plug.Conn.send_resp(conn, 204, "")

        method when method in ["GET", "HEAD"] and key == "" ->
          # list_objects (the probe's read step)
          conn
          |> Plug.Conn.put_resp_content_type("application/xml")
          |> Plug.Conn.send_resp(
            200,
            ~s(<?xml version="1.0"?><ListBucketResult><Name>b</Name><IsTruncated>false</IsTruncated></ListBucketResult>)
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

    previous = Application.get_env(:ex_aws, :req_opts)
    Application.put_env(:ex_aws, :req_opts, plug: {Req.Test, @stub})

    secret = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-e2e")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ex_aws, :req_opts, previous),
        else: Application.delete_env(:ex_aws, :req_opts)

      if secret,
        do: Application.put_env(:phoenix_kit, :secret_key_base, secret),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)
    end)

    {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("storage_user_buckets_enabled", true)

    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{name: "E2E #{n}"})

    for key <- ~w(storage storage.create_library storage.own_storage integrations) do
      {:ok, _} = Permissions.grant_permission(role.uuid, key)
    end

    {:ok, user} =
      Auth.register_user(%{
        "email" => "e2e-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, _} = Roles.assign_role(user, role.name)
    user = Repo.get!(Auth.User, user.uuid)

    root = Path.join(System.tmp_dir!(), "pk_e2e_site_#{n}")

    {:ok, site} =
      Storage.create_bucket(%{
        name: "e2e-site-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true
      })

    :persistent_term.erase(:phoenix_kit_buckets_cache)

    on_exit(fn ->
      :persistent_term.erase(:phoenix_kit_buckets_cache)
      File.rm_rf(root)
    end)

    %{user: user, store: store, site: site, root: root}
  end

  defp scope(user), do: Scope.for_user(Repo.get!(Auth.User, user.uuid))

  defp create_library!(user, mode) do
    {:ok, %{uuid: connection}} =
      Integrations.add_connection("object_storage", "mine", nil, owner: {:user, user.uuid})

    {:ok, _} =
      Integrations.save_setup(connection, %{"access_key" => "AKIA", "secret_key" => "s"}, nil,
        owner: {:user, user.uuid}
      )

    {:ok, library} =
      Libraries.create_user_library(scope(user), %{
        "name" => "Photos #{System.unique_integer([:positive])}",
        "storage" => %{
          "mode" => mode,
          "integration_uuid" => connection,
          "provider" => "s3",
          "bucket_name" => "my-photos",
          "region" => "eu-central-1",
          "endpoint" => "https://8.8.8.8"
        }
      })

    library
  end

  defp upload!(user, library, content) do
    source = Path.join(System.tmp_dir!(), "pk_e2e_#{System.unique_integer([:positive])}.txt")
    File.write!(source, content)
    checksum = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

    {result, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        Storage.store_file_in_buckets(source, "document", user.uuid, checksum, "txt", "a.txt",
          library_uuid: library.uuid
        )
      end)

    File.rm(source)
    result
  end

  test "creating the library really probes the bucket (list, write, delete)", %{
    user: user,
    store: store
  } do
    library = create_library!(user, "only")

    assert library.storage_profile_uuid
    # The probe wrote its file and deleted it again.
    assert Agent.get(store, & &1) == %{}
  end

  test "an upload lands in the user's bucket only, and is read back from it", ctx do
    library = create_library!(ctx.user, "only")

    assert {:ok, file} = upload!(ctx.user, library, "my private photo")
    assert file.library_uuid == library.uuid

    # In the user's bucket…
    assert [{key, "my private photo"}] = Agent.get(ctx.store, &Enum.to_list/1)
    assert String.starts_with?(key, library.key_prefix <> "/")

    # …located there, and not on the site's bucket…
    locations = Repo.all(from(l in FileLocation, where: l.path == ^key, select: l.bucket_uuid))
    [owned] = Storage.list_owned_buckets(ctx.user.uuid)
    assert Enum.map(locations, &to_string/1) == [to_string(owned.uuid)]
    refute File.exists?(Path.join(ctx.root, key))

    # …and read back through it.
    assert {:ok, path} = Manager.retrieve_file(key)
    assert File.read!(path) == "my private photo"
    File.rm(path)
  end

  test "backup mode keeps the site's copy and adds the user's", ctx do
    library = create_library!(ctx.user, "backup")

    assert {:ok, _file} = upload!(ctx.user, library, "backed up")

    assert [{key, "backed up"}] = Agent.get(ctx.store, &Enum.to_list/1)
    assert File.exists?(Path.join(ctx.root, key))
  end

  test "deleting the file deletes the object from the user's bucket", ctx do
    library = create_library!(ctx.user, "only")
    {:ok, file} = upload!(ctx.user, library, "to be deleted")
    assert [{_key, _body}] = Agent.get(ctx.store, &Enum.to_list/1)

    assert {:ok, _} = Storage.delete_file_completely(file)

    assert Agent.get(ctx.store, & &1) == %{}
  end

  test "purging the library removes its files, bucket and profile", ctx do
    library = create_library!(ctx.user, "only")
    {:ok, _file} = upload!(ctx.user, library, "gone with the library")
    [owned] = Storage.list_owned_buckets(ctx.user.uuid)

    {:ok, trashed} = Libraries.trash_library(scope(ctx.user), library)
    assert :ok = Libraries.purge_library(trashed)

    assert Agent.get(ctx.store, & &1) == %{}
    assert Storage.get_bucket(owned.uuid) == nil
    assert Storage.list_owned_buckets(ctx.user.uuid) == []
  end

  test "a miss on a key nobody has never probes the user's bucket", ctx do
    library = create_library!(ctx.user, "only")
    {:ok, _file} = upload!(ctx.user, library, "mine")
    before = Agent.get(ctx.store, & &1)

    {located, fallback} = Manager.read_order("nobody/ab/hash/x.txt", [], :read)

    assert located == []
    [owned] = Storage.list_owned_buckets(ctx.user.uuid)
    refute to_string(owned.uuid) in Enum.map(fallback, &to_string(&1.uuid))
    assert Agent.get(ctx.store, & &1) == before
  end
end
