defmodule PhoenixKit.Migrations.Postgres.V205Test do
  @moduledoc """
  V205's storage profiles and variant sets, run as the real SQL: the two
  Default rows are seeded from the global settings, every bucket joins the
  Default profile in today's read order, sizes move into the Default set and
  are unique per set, existing instances get the spec hash Elixir computes,
  under-replicated files start stale, and a re-run and a round trip change
  nothing.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V205
  alias PhoenixKit.Modules.Storage.{Dimension, VariantSets}
  alias PhoenixKit.Test.Repo

  @profile "00000000-0000-7000-8000-000000000002"
  @set "00000000-0000-7000-8000-000000000003"

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp setting!(key, value) do
    query(
      """
      INSERT INTO public.phoenix_kit_settings (key, value, date_added, date_updated)
      VALUES ($1, $2, NOW(), NOW())
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
      """,
      [key, value]
    )
  end

  defp bucket!(provider, priority, enabled \\ true) do
    [[uuid]] =
      query(
        """
        INSERT INTO public.phoenix_kit_buckets (name, provider, enabled, priority, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, NOW(), NOW())
        RETURNING uuid::text
        """,
        ["v205-#{System.unique_integer([:positive])}", provider, enabled, priority]
      )

    uuid
  end

  defp file!(instances) do
    [[user]] =
      query("""
      INSERT INTO public.phoenix_kit_users (email, hashed_password, inserted_at, updated_at)
      VALUES ('v205-#{System.unique_integer([:positive])}@example.com', 'x', NOW(), NOW())
      RETURNING uuid::text
      """)

    [[file]] =
      query(
        """
        INSERT INTO public.phoenix_kit_files
          (original_file_name, file_name, file_path, mime_type, file_type, ext, file_checksum,
           user_file_checksum, size, status, user_uuid, inserted_at, updated_at)
        VALUES ('a.png', 'a.png', 'x', 'image/png', 'image', 'png', $1, $1, 1, 'active',
                $2::text::uuid, NOW(), NOW())
        RETURNING uuid::text
        """,
        [Ecto.UUID.generate(), user]
      )

    instance_uuids =
      for {variant, buckets} <- instances do
        [[instance]] =
          query(
            """
            INSERT INTO public.phoenix_kit_file_instances
              (file_uuid, variant_name, file_name, mime_type, ext, checksum, size,
               processing_status, inserted_at, updated_at)
            VALUES ($1::text::uuid, $2, $3, 'image/png', 'png', 'c', 1, 'completed', NOW(), NOW())
            RETURNING uuid::text
            """,
            [file, variant, "x/#{file}_#{variant}.png"]
          )

        for bucket <- buckets do
          query(
            """
            INSERT INTO public.phoenix_kit_file_locations
              (path, status, priority, file_instance_uuid, bucket_uuid, inserted_at, updated_at)
            VALUES ($1, 'active', 0, $2::text::uuid, $3::text::uuid, NOW(), NOW())
            """,
            ["x/#{file}_#{variant}.png", instance, bucket]
          )
        end

        {variant, instance}
      end

    {file, Map.new(instance_uuids)}
  end

  defp placed(file) do
    [[profile, revision]] =
      query(
        "SELECT placed_profile_uuid::text, placed_revision FROM public.phoenix_kit_files WHERE uuid = $1::text::uuid",
        [file]
      )

    {profile, revision}
  end

  defp spec_hash(instance) do
    [[hash]] =
      query(
        "SELECT spec_hash FROM public.phoenix_kit_file_instances WHERE uuid = $1::text::uuid",
        [instance]
      )

    hash
  end

  # Only the Default's own rows are cleared, so the test's buckets are all
  # the Default holds when `up` seeds it again.
  defp reset! do
    run(V205.down_statements("public"))
    query("DELETE FROM public.phoenix_kit_buckets")
    query("DELETE FROM public.phoenix_kit_storage_dimensions")
  end

  test "the chain is at 205 or later, with both defaults" do
    assert String.to_integer(marker()) >= 205

    assert [["Default", true]] =
             query(
               "SELECT name, is_default FROM public.phoenix_kit_storage_profiles WHERE uuid = $1::text::uuid",
               [@profile]
             )

    assert [["Default", true, true]] =
             query(
               "SELECT name, is_default, selectable FROM public.phoenix_kit_variant_sets WHERE uuid = $1::text::uuid",
               [@set]
             )
  end

  test "the Default profile and set come from the global settings" do
    reset!()
    setting!("storage_redundancy_copies", "3")
    setting!("storage_auto_generate_variants", "false")
    setting!("storage_tile_generation_enabled", "true")

    run(V205.up_statements("public"))

    assert [[3, 3, 1, 1]] =
             query(
               "SELECT copies_originals, copies_variants, min_copies_on_write, revision FROM public.phoenix_kit_storage_profiles WHERE uuid = $1::text::uuid",
               [@profile]
             )

    assert [[false, true]] =
             query(
               "SELECT generate_variants, generate_tiles FROM public.phoenix_kit_variant_sets WHERE uuid = $1::text::uuid",
               [@set]
             )
  end

  test "a copy count out of range is clamped" do
    reset!()
    setting!("storage_redundancy_copies", "9")
    run(V205.up_statements("public"))

    assert [[5]] =
             query(
               "SELECT copies_originals FROM public.phoenix_kit_storage_profiles WHERE uuid = $1::text::uuid",
               [@profile]
             )
  end

  test "every bucket joins the Default in today's read order: local first, then priority" do
    reset!()
    remote_first = bucket!("s3", 1)
    pooled_local = bucket!("local", 0)
    remote_second = bucket!("s3", 2)
    disabled = bucket!("s3", 3, false)

    run(V205.up_statements("public"))

    rows =
      query(
        """
        SELECT bucket_uuid::text, role, stores, write_priority, serve_order, status
        FROM public.phoenix_kit_storage_profile_buckets
        WHERE profile_uuid = $1::text::uuid
        ORDER BY serve_order
        """,
        [@profile]
      )

    assert rows == [
             [pooled_local, "primary", "all", nil, 1, "active"],
             [remote_first, "primary", "all", 1, 2, "active"],
             [remote_second, "primary", "all", 2, 3, "active"],
             [disabled, "primary", "all", 3, 4, "active"]
           ]
  end

  test "a re-run does not put back a bucket taken out of the Default" do
    reset!()
    kept = bucket!("local", 0)
    removed = bucket!("s3", 1)
    run(V205.up_statements("public"))

    query(
      "DELETE FROM public.phoenix_kit_storage_profile_buckets WHERE bucket_uuid = $1::text::uuid",
      [removed]
    )

    run(V205.up_statements("public"))

    assert [[^kept]] =
             query(
               "SELECT bucket_uuid::text FROM public.phoenix_kit_storage_profile_buckets WHERE profile_uuid = $1::text::uuid",
               [@profile]
             )
  end

  test "a bucket a profile uses cannot be deleted" do
    bucket = bucket!("local", 0)

    query(
      """
      INSERT INTO public.phoenix_kit_storage_profile_buckets (profile_uuid, bucket_uuid)
      VALUES ($1::text::uuid, $2::text::uuid)
      """,
      [@profile, bucket]
    )

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          query("DELETE FROM public.phoenix_kit_buckets WHERE uuid = $1::text::uuid", [bucket])
        end)
      end

    assert error.postgres.code == :restrict_violation
  end

  test "sizes move into the Default set, and names are unique per set" do
    reset!()

    query("""
    INSERT INTO public.phoenix_kit_storage_dimensions
      (name, width, height, quality, applies_to, inserted_at, updated_at)
    VALUES ('thumbnail', 150, 150, 85, 'image', NOW(), NOW())
    """)

    run(V205.up_statements("public"))

    assert [[@set]] =
             query("SELECT variant_set_uuid::text FROM public.phoenix_kit_storage_dimensions")

    [[other]] =
      query("""
      INSERT INTO public.phoenix_kit_variant_sets (name, inserted_at, updated_at)
      VALUES ('Photos', NOW(), NOW()) RETURNING uuid::text
      """)

    query(
      """
      INSERT INTO public.phoenix_kit_storage_dimensions
        (name, width, quality, applies_to, variant_set_uuid, inserted_at, updated_at)
      VALUES ('thumbnail', 300, 85, 'image', $1::text::uuid, NOW(), NOW())
      """,
      [other]
    )

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          query("""
          INSERT INTO public.phoenix_kit_storage_dimensions
            (name, width, quality, applies_to, inserted_at, updated_at)
          VALUES ('thumbnail', 64, 85, 'image', NOW(), NOW())
          """)
        end)
      end

    assert error.postgres.code == :unique_violation
  end

  test "instances named like a size get the spec hash Elixir computes; others get none" do
    reset!()

    query("""
    INSERT INTO public.phoenix_kit_storage_dimensions
      (name, width, height, quality, format, applies_to, maintain_aspect_ratio,
       alternative_formats, inserted_at, updated_at)
    VALUES ('medium', 800, NULL, 85, NULL, 'image', true, '{webp}', NOW(), NOW())
    """)

    {_file, instances} = file!([{"original", []}, {"medium", []}, {"medium_webp", []}])

    run(V205.up_statements("public"))

    medium = %Dimension{
      name: "medium",
      width: 800,
      height: nil,
      quality: 85,
      format: nil,
      maintain_aspect_ratio: true
    }

    assert spec_hash(instances["medium"]) == VariantSets.spec_hash(medium)
    assert spec_hash(instances["medium_webp"]) == VariantSets.spec_hash(medium, "webp")
    refute spec_hash(instances["medium"]) == spec_hash(instances["medium_webp"])
    assert spec_hash(instances["original"]) == nil
  end

  test "only under-replicated files start stale" do
    reset!()
    setting!("storage_redundancy_copies", "2")
    a = bucket!("local", 0)
    b = bucket!("s3", 1)
    disabled = bucket!("s3", 2, false)

    {healthy, _} = file!([{"original", [a, b]}, {"thumbnail", [a, b]}])
    {short, _} = file!([{"original", [a, b]}, {"thumbnail", [a]}])
    {on_disabled, _} = file!([{"original", [a, disabled]}])

    run(V205.up_statements("public"))

    assert placed(healthy) == {nil, nil}
    assert placed(short) == {@profile, 0}
    assert placed(on_disabled) == {@profile, 0}
  end

  test "the copy target is capped at the number of enabled buckets" do
    reset!()
    setting!("storage_redundancy_copies", "3")
    only = bucket!("local", 0)
    {file, _} = file!([{"original", [only]}])

    run(V205.up_statements("public"))

    assert placed(file) == {nil, nil}
  end

  test "a round trip ends where it started" do
    run(V205.down_statements("public"))
    assert marker() == "204"

    assert [] =
             query(
               "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'phoenix_kit_storage_profiles'"
             )

    assert [
             [
               "CREATE UNIQUE INDEX phoenix_kit_storage_dimensions_name_index ON public.phoenix_kit_storage_dimensions USING btree (name)"
             ]
           ] =
             query(
               "SELECT indexdef FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'phoenix_kit_storage_dimensions_name_index'"
             )

    run(V205.up_statements("public"))
    run(V205.up_statements("public"))
    assert marker() == "205"

    assert [[def]] =
             query(
               "SELECT indexdef FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'phoenix_kit_storage_dimensions_name_index'"
             )

    assert def =~ "(variant_set_uuid, name)"

    refute Enum.any?(
             query("""
             SELECT c.conname FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid
             WHERE t.relname = 'phoenix_kit_storage_dimensions'
             """),
             fn [name] -> name == "phoenix_kit_storage_dimensions_variant_set_not_null" end
           )
  end
end
