defmodule PhoenixKit.Migrations.Postgres.V206Test do
  @moduledoc """
  V206's user-owned storage columns, run as the real SQL: an owner on buckets
  and profiles, the check that keeps an owned bucket off the filesystem and off
  keys of its own, and a re-run and a round trip that change nothing for the
  site's own rows.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V206
  alias PhoenixKit.Test.Repo

  @owner "01a0f33e-0000-7000-8000-00000000aaaa"
  @connection "01a0f33e-0000-7000-8000-00000000bbbb"

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp columns(table) do
    query(
      """
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = $1 AND column_name = 'owner_uuid'
      """,
      [table]
    )
  end

  defp bucket(provider, owner, integration, access_type \\ "signed") do
    query(
      """
      INSERT INTO public.phoenix_kit_buckets
        (name, provider, owner_uuid, integration_uuid, access_type, enabled, priority, inserted_at, updated_at)
      VALUES ($1, $2, $3::text::uuid, $4::text::uuid, $5, true, 0, NOW(), NOW())
      RETURNING uuid::text
      """,
      ["v206-#{System.unique_integer([:positive])}", provider, owner, integration, access_type]
    )
  end

  defp check_violation?(fun) do
    fun.()
    false
  rescue
    error in Postgrex.Error -> error.postgres.code == :check_violation
  end

  test "the chain is at 206 or later, with an owner on buckets and profiles" do
    assert String.to_integer(marker()) >= 206
    assert columns("phoenix_kit_buckets") == [["owner_uuid"]]
    assert columns("phoenix_kit_storage_profiles") == [["owner_uuid"]]
  end

  test "a site bucket needs no owner, and a cloud bucket of the site needs no connection" do
    assert [[_]] = bucket("local", nil, nil, "public")
    assert [[_]] = bucket("s3", nil, nil, "public")
  end

  describe "an owned bucket" do
    test "may be a cloud bucket on a connection" do
      assert [[_]] = bucket("s3", @owner, @connection)
      assert [[_]] = bucket("r2", @owner, @connection)
    end

    test "is never a filesystem path" do
      assert check_violation?(fn -> bucket("local", @owner, @connection) end)
    end

    test "never hands out a plain object URL" do
      assert check_violation?(fn -> bucket("s3", @owner, @connection, "public") end)
      assert [[_]] = bucket("s3", @owner, @connection, "private")
    end

    test "never carries keys of its own: it needs a connection" do
      assert check_violation?(fn -> bucket("s3", @owner, nil) end)
    end
  end

  test "a re-run changes nothing" do
    [[uuid]] = bucket("s3", @owner, @connection)

    run(V206.up_statements("public"))

    assert [[^uuid]] =
             query(
               "SELECT uuid::text FROM public.phoenix_kit_buckets WHERE uuid = $1::text::uuid",
               [uuid]
             )

    assert String.to_integer(marker()) >= 206
  end

  test "a round trip removes what belongs to users and keeps what belongs to the site" do
    [[user]] =
      query("""
      INSERT INTO public.phoenix_kit_users (email, hashed_password, inserted_at, updated_at)
      VALUES ('v206-#{System.unique_integer([:positive])}@example.com', 'x', NOW(), NOW())
      RETURNING uuid::text
      """)

    [[site]] = bucket("s3", nil, nil)

    [[owned]] =
      bucket("s3", user, @connection)

    [[profile]] =
      query(
        """
        INSERT INTO public.phoenix_kit_storage_profiles (name, owner_uuid, inserted_at, updated_at)
        VALUES ($1, $2::text::uuid, NOW(), NOW())
        RETURNING uuid::text
        """,
        ["v206-profile-#{System.unique_integer([:positive])}", user]
      )

    query(
      """
      INSERT INTO public.phoenix_kit_storage_profile_buckets
        (profile_uuid, bucket_uuid, role, stores, serve_order, status, inserted_at, updated_at)
      VALUES ($1::text::uuid, $2::text::uuid, 'primary', 'all', 1, 'active', NOW(), NOW())
      """,
      [profile, owned]
    )

    [[library]] =
      query(
        """
        INSERT INTO public.phoenix_kit_storage_libraries
          (name, kind, owner_uuid, visibility, key_prefix, slug, storage_profile_uuid, inserted_at, updated_at)
        VALUES ('v206 library', 'user', $2::text::uuid, 'private',
                'v206', 'v206', $1::text::uuid, NOW(), NOW())
        RETURNING uuid::text
        """,
        [profile, user]
      )

    run(V206.down_statements("public"))

    assert columns("phoenix_kit_buckets") == []
    assert columns("phoenix_kit_storage_profiles") == []

    # The user's library is back on the Default; the site's bucket is still there.
    assert [[nil]] =
             query(
               "SELECT storage_profile_uuid FROM public.phoenix_kit_storage_libraries WHERE uuid = $1::text::uuid",
               [library]
             )

    assert [[1]] =
             query(
               "SELECT count(*)::int FROM public.phoenix_kit_buckets WHERE uuid = $1::text::uuid",
               [site]
             )

    assert [[0]] =
             query(
               "SELECT count(*)::int FROM public.phoenix_kit_buckets WHERE uuid = $1::text::uuid",
               [owned]
             )

    assert [[0]] =
             query(
               "SELECT count(*)::int FROM public.phoenix_kit_storage_profiles WHERE uuid = $1::text::uuid",
               [profile]
             )

    run(V206.up_statements("public"))

    assert columns("phoenix_kit_buckets") == [["owner_uuid"]]
    assert String.to_integer(marker()) >= 206
  end
end
