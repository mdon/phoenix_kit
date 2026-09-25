defmodule PhoenixKit.Migrations.Postgres.V204Test do
  @moduledoc """
  V204's location rules, run as the real SQL: duplicate location rows are
  removed keeping the oldest, the `(instance, bucket)` pair is unique from
  then on, a bucket that still holds a location cannot be deleted, and a
  re-run and a round trip change nothing.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V204
  alias PhoenixKit.Test.Repo

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp on_delete do
    [[action]] =
      query("""
      SELECT c.confdeltype::text FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      WHERE c.conname = 'phoenix_kit_file_locations_bucket_id_fkey'
        AND t.relname = 'phoenix_kit_file_locations' AND n.nspname = 'public'
      """)

    action
  end

  defp bucket! do
    [[uuid]] =
      query("""
      INSERT INTO public.phoenix_kit_buckets (name, provider, enabled, priority, inserted_at, updated_at)
      VALUES ('v204-#{System.unique_integer([:positive])}', 'local', true, 0, NOW(), NOW())
      RETURNING uuid::text
      """)

    uuid
  end

  defp instance! do
    [[user]] =
      query("""
      INSERT INTO public.phoenix_kit_users (email, hashed_password, inserted_at, updated_at)
      VALUES ('v204-#{System.unique_integer([:positive])}@example.com', 'x', NOW(), NOW())
      RETURNING uuid::text
      """)

    [[file]] =
      query(
        """
        INSERT INTO public.phoenix_kit_files
          (original_file_name, file_name, file_path, mime_type, file_type, ext, file_checksum,
           user_file_checksum, size, status, user_uuid, inserted_at, updated_at)
        VALUES ('a.png', 'a.png', 'x/a.png', 'image/png', 'image', 'png', $1, $1, 1, 'active',
                $2::text::uuid, NOW(), NOW())
        RETURNING uuid::text
        """,
        [Ecto.UUID.generate(), user]
      )

    [[instance]] =
      query(
        """
        INSERT INTO public.phoenix_kit_file_instances
          (file_uuid, variant_name, file_name, mime_type, ext, checksum, size, processing_status,
           inserted_at, updated_at)
        VALUES ($1::text::uuid, 'original', 'x/a_original.png', 'image/png', 'png', 'c', 1,
                'completed', NOW(), NOW())
        RETURNING uuid::text
        """,
        [file]
      )

    instance
  end

  defp location!(instance, bucket, age_seconds \\ 0) do
    [[uuid]] =
      query(
        """
        INSERT INTO public.phoenix_kit_file_locations
          (path, status, priority, file_instance_uuid, bucket_uuid, inserted_at, updated_at)
        VALUES ('x/a_original.png', 'active', 0, $1::text::uuid, $2::text::uuid,
                NOW() - make_interval(secs => $3), NOW())
        RETURNING uuid::text
        """,
        [instance, bucket, age_seconds]
      )

    uuid
  end

  defp count_locations(instance) do
    [[n]] =
      query(
        "SELECT count(*)::int FROM public.phoenix_kit_file_locations WHERE file_instance_uuid = $1::text::uuid",
        [instance]
      )

    n
  end

  test "the chain is at 204: one row per pair, and a bucket with files is kept" do
    assert marker() == "204"
    assert on_delete() == "r"

    instance = instance!()
    bucket = bucket!()
    location!(instance, bucket)

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn -> location!(instance, bucket) end)
      end

    assert error.postgres.code == :unique_violation

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          query("DELETE FROM public.phoenix_kit_buckets WHERE uuid = $1::text::uuid", [bucket])
        end)
      end

    assert error.postgres.code == :restrict_violation
  end

  test "up removes duplicates, keeping the oldest; a re-run changes nothing" do
    run(V204.down_statements("public"))

    instance = instance!()
    bucket = bucket!()
    location!(instance, bucket)
    first = location!(instance, bucket, 3600)
    location!(instance, bucket)
    other_bucket = bucket!()
    location!(instance, other_bucket)
    assert count_locations(instance) == 4

    run(V204.up_statements("public"))
    run(V204.up_statements("public"))

    assert count_locations(instance) == 2

    assert [[^first]] =
             query(
               "SELECT uuid::text FROM public.phoenix_kit_file_locations WHERE file_instance_uuid = $1::text::uuid AND bucket_uuid = $2::text::uuid",
               [instance, bucket]
             )

    assert marker() == "204"
    assert on_delete() == "r"

    refute Enum.any?(
             query("""
             SELECT c.conname FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid
             WHERE t.relname = 'phoenix_kit_file_locations'
             """),
             fn [name] -> String.ends_with?(name, "_v204") end
           )
  end

  test "down puts the cascade back and drops the index" do
    run(V204.down_statements("public"))

    assert marker() == "203"
    assert on_delete() == "c"

    assert [] =
             query("""
             SELECT 1 FROM pg_indexes WHERE schemaname = 'public'
               AND indexname = 'phoenix_kit_file_locations_instance_bucket_index'
             """)
  end
end
