defmodule PhoenixKit.Modules.Storage.UserBucketReadPathTest do
  @moduledoc """
  Where a read goes when a file lives on a user's own bucket (V206): the
  buckets its location rows name are reached although the site's pool leaves
  them out, the fallback that tries every other bucket never includes one, a
  disabled one is skipped, and the objects of a user's library are deleted from
  that user's buckets only.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{FileLocation, Library, Manager, Profiles}
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  @cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@cache)
    original = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-read-path")

    on_exit(fn ->
      :persistent_term.erase(@cache)

      if original,
        do: Application.put_env(:phoenix_kit, :secret_key_base, original),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)
    end)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "read-path-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, site} =
      Storage.create_bucket(%{
        name: "read-path-site-#{System.unique_integer([:positive])}",
        provider: "local",
        endpoint: Path.join(System.tmp_dir!(), "pk_read_path"),
        enabled: true
      })

    %{user: user, site: site, owned: owned_bucket!(user.uuid)}
  end

  defp owned_bucket!(owner) do
    {:ok, %{uuid: connection}} =
      Integrations.add_connection("object_storage", "mine", nil, owner: {:user, owner})

    {:ok, _} =
      Integrations.save_setup(
        connection,
        %{"access_key" => "AKIA", "secret_key" => "s"},
        nil,
        owner: {:user, owner}
      )

    {:ok, bucket} =
      Storage.create_owned_bucket(owner, %{
        "name" => "Mine #{System.unique_integer([:positive])}",
        "provider" => "s3",
        "bucket_name" => "mine",
        "region" => "eu-central-1",
        "integration_uuid" => connection
      })

    bucket
  end

  defp located!(user, key, bucket) do
    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "a.txt",
        file_name: Path.basename(key),
        file_path: Path.dirname(key),
        mime_type: "text/plain",
        file_type: "document",
        ext: "txt",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        user_uuid: user.uuid
      })

    {:ok, instance} =
      Storage.create_file_instance(%{
        variant_name: "original",
        file_name: key,
        mime_type: "text/plain",
        ext: "txt",
        checksum: "c",
        size: 1,
        processing_status: "completed",
        file_uuid: file.uuid
      })

    Repo.insert!(%FileLocation{
      path: key,
      status: "active",
      priority: 0,
      file_instance_uuid: instance.uuid,
      bucket_uuid: bucket.uuid
    })

    file
  end

  defp key, do: "rp#{System.unique_integer([:positive])}/ab/hash/a_original.txt"

  defp uuids(buckets), do: Enum.map(buckets, &to_string(&1.uuid))

  test "a located user bucket is read from, and is never in the fallback", ctx do
    key = key()
    located!(ctx.user, key, ctx.owned)

    {located, fallback} = Manager.read_order(key, [], :read)

    assert uuids(located) == [to_string(ctx.owned.uuid)]
    assert to_string(ctx.owned.uuid) not in uuids(fallback)
    assert to_string(ctx.site.uuid) in uuids(fallback)
  end

  test "a miss on a site file never probes a user's bucket", ctx do
    key = key()
    located!(ctx.user, key, ctx.site)

    {located, fallback} = Manager.read_order(key, [], :read)

    assert uuids(located) == [to_string(ctx.site.uuid)]
    refute to_string(ctx.owned.uuid) in uuids(fallback)
    refute to_string(ctx.owned.uuid) in uuids(located)
  end

  test "a key no row names probes the site's pool only", ctx do
    {located, fallback} = Manager.read_order(key(), [], :read)

    assert located == []
    assert to_string(ctx.site.uuid) in uuids(fallback)
    refute to_string(ctx.owned.uuid) in uuids(fallback)
  end

  test "a disabled user bucket is not read from", ctx do
    key = key()
    located!(ctx.user, key, ctx.owned)
    {:ok, _} = ctx.owned |> Ecto.Changeset.change(enabled: false) |> Repo.update()

    {located, _fallback} = Manager.read_order(key, [], :read)

    assert located == []
  end

  describe "deleting the objects of a user's library" do
    test "reaches the own buckets of that library's profile, and only those", ctx do
      {:ok, other} =
        Auth.register_user(%{
          "email" => "read-path-other-#{System.unique_integer([:positive])}@example.com",
          "password" => "ValidPassword123!"
        })

      others_bucket = owned_bucket!(other.uuid)
      second_bucket = owned_bucket!(ctx.user.uuid)

      mine = library_on!(ctx.user, ctx.owned)
      theirs = library_on!(other, others_bucket)
      _second = library_on!(ctx.user, second_bucket)

      assert [%{uuid: uuid}] = Storage.owned_buckets_for_dir("#{mine.key_prefix}/ab/hash")
      assert uuid == ctx.owned.uuid

      assert [%{uuid: uuid}] = Storage.owned_buckets_for_dir("#{theirs.key_prefix}/ab/hash")
      assert uuid == others_bucket.uuid

      # A site library's prefix, or none at all, reaches nothing.
      assert Storage.owned_buckets_for_dir("nobody/ab/hash") == []
      assert Storage.owned_buckets_for_dir(".") == []
    end

    test "still finds them once the owner is gone (the library has no owner left)", ctx do
      library = library_on!(ctx.user, ctx.owned)

      # What the owner's deletion leaves: a trashed library with no owner.
      library
      |> Ecto.Changeset.change(
        owner_uuid: nil,
        slug: nil,
        trashed_at: DateTime.truncate(DateTime.utc_now(), :second)
      )
      |> Repo.update!()

      assert [%{uuid: uuid}] = Storage.owned_buckets_for_dir("#{library.key_prefix}/ab/hash")
      assert uuid == ctx.owned.uuid
    end
  end

  defp library_on!(user, bucket) do
    slug = "lib#{System.unique_integer([:positive])}"

    library =
      Repo.insert!(%Library{
        name: "Mine #{slug}",
        kind: "user",
        owner_uuid: user.uuid,
        visibility: "private",
        key_prefix: slug,
        slug: slug
      })

    {:ok, profile} = Profiles.create_user_profile(user.uuid, bucket, :only)
    {:ok, library} = Profiles.assign_user_profile(library, profile)
    library
  end
end
