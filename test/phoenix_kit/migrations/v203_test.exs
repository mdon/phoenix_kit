defmodule PhoenixKit.Migrations.Postgres.V203Test do
  @moduledoc """
  V203's user libraries, run as the real SQL: deleting a user keeps their
  files and folders (uploader and creator become NULL), a user's live
  library blocks their deletion until it is trashed, members go with their
  library and their user, a re-run and a round trip change nothing, and a
  database that ran V202 before the slug existed gets it (#871).
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.{V202, V203}
  alias PhoenixKit.Test.Repo

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)

  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  # {on_delete action code, definition} of a constraint, or nil.
  defp constraint(table, name) do
    case query(
           """
           SELECT c.confdeltype::text, pg_get_constraintdef(c.oid)
           FROM pg_constraint c
           JOIN pg_class t ON t.oid = c.conrelid
           JOIN pg_namespace n ON n.oid = t.relnamespace
           WHERE c.conname = $1 AND t.relname = $2 AND n.nspname = 'public'
           """,
           [name, table]
         ) do
      [[action, definition]] -> {action, definition}
      [] -> nil
    end
  end

  defp constraint_names(table) do
    query(
      """
      SELECT c.conname FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      WHERE t.relname = $1 AND n.nspname = 'public'
      ORDER BY c.conname
      """,
      [table]
    )
    |> List.flatten()
  end

  defp user! do
    [[uuid]] =
      query("""
      INSERT INTO public.phoenix_kit_users (email, hashed_password, inserted_at, updated_at)
      VALUES ('v203-#{System.unique_integer([:positive])}@example.com', 'x', NOW(), NOW())
      RETURNING uuid::text
      """)

    uuid
  end

  defp file!(user_uuid) do
    [[uuid]] =
      query(
        """
        INSERT INTO public.phoenix_kit_files
          (original_file_name, file_name, file_path, mime_type, file_type, ext, file_checksum,
           user_file_checksum, size, status, user_uuid, inserted_at, updated_at)
        VALUES ('a.png', 'a.png', 'x/a.png', 'image/png', 'image', 'png', $1, $1, 1, 'active',
                $2::text::uuid, NOW(), NOW())
        RETURNING uuid::text
        """,
        [Ecto.UUID.generate(), user_uuid]
      )

    uuid
  end

  defp folder!(user_uuid) do
    [[uuid]] =
      query(
        """
        INSERT INTO public.phoenix_kit_media_folders (name, user_uuid, inserted_at, updated_at)
        VALUES ($1, $2::text::uuid, NOW(), NOW()) RETURNING uuid::text
        """,
        ["v203-#{System.unique_integer([:positive])}", user_uuid]
      )

    uuid
  end

  defp user_library!(owner_uuid, name) do
    [[uuid]] =
      query(
        """
        INSERT INTO public.phoenix_kit_storage_libraries
          (name, kind, owner_uuid, visibility, slug, inserted_at, updated_at)
        VALUES ($1, 'user', $2::text::uuid, 'private', $3, NOW(), NOW())
        RETURNING uuid::text
        """,
        [name, owner_uuid, "v203-#{System.unique_integer([:positive])}"]
      )

    uuid
  end

  defp delete_user(uuid),
    do: Repo.query("DELETE FROM public.phoenix_kit_users WHERE uuid = $1::text::uuid", [uuid])

  defp column(table, uuid, column) do
    [[value]] =
      query("SELECT #{column}::text FROM public.#{table} WHERE uuid = $1::text::uuid", [uuid])

    value
  end

  test "the chain is at 203 or later, with the new rules" do
    assert String.to_integer(marker()) >= 203

    assert {"n", _} = constraint("phoenix_kit_files", "fk_files_user_uuid")

    assert {_, check} = constraint("phoenix_kit_files", "phoenix_kit_files_user_or_parent_check")
    assert check =~ "library_uuid IS NOT NULL"

    assert {"n", _} =
             constraint("phoenix_kit_media_folders", "phoenix_kit_media_folders_user_uuid_fkey")

    assert {"n", _} =
             constraint(
               "phoenix_kit_storage_libraries",
               "phoenix_kit_storage_libraries_owner_uuid_fkey"
             )

    assert {_, owner_check} =
             constraint(
               "phoenix_kit_storage_libraries",
               "phoenix_kit_storage_libraries_owner_check"
             )

    assert owner_check =~ "trashed_at IS NOT NULL"
  end

  test "deleting a user keeps their files and folders, without an uploader" do
    user = user!()
    file = file!(user)
    folder = folder!(user)

    assert {:ok, _} = delete_user(user)

    assert column("phoenix_kit_files", file, "user_uuid") == nil
    assert column("phoenix_kit_media_folders", folder, "user_uuid") == nil
  end

  test "a user's live library blocks deleting them; a trashed one lets them go" do
    user = user!()
    library = user_library!(user, "Personal")

    # In a nested transaction (a savepoint), so the refused delete leaves the
    # test's own transaction usable.
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.query!("DELETE FROM public.phoenix_kit_users WHERE uuid = $1::text::uuid", [user])
        end)
      end

    assert error.postgres.code == :check_violation

    query(
      "UPDATE public.phoenix_kit_storage_libraries SET trashed_at = NOW() WHERE uuid = $1::text::uuid",
      [library]
    )

    assert {:ok, _} = delete_user(user)
    assert column("phoenix_kit_storage_libraries", library, "owner_uuid") == nil
  end

  test "a member row goes with its library and with its user" do
    owner = user!()
    member = user!()
    other = user!()
    library = user_library!(owner, "Shared")

    for user <- [member, other] do
      query(
        """
        INSERT INTO public.phoenix_kit_storage_library_members (library_uuid, user_uuid, role)
        VALUES ($1::text::uuid, $2::text::uuid, 'viewer')
        """,
        [library, user]
      )
    end

    assert {:ok, _} = delete_user(member)

    assert [[1]] =
             query(
               "SELECT count(*)::int FROM public.phoenix_kit_storage_library_members WHERE library_uuid = $1::text::uuid",
               [library]
             )

    query("DELETE FROM public.phoenix_kit_storage_libraries WHERE uuid = $1::text::uuid", [
      library
    ])

    assert [[0]] =
             query(
               "SELECT count(*)::int FROM public.phoenix_kit_storage_library_members WHERE user_uuid = $1::text::uuid",
               [other]
             )
  end

  test "a member's role is one of three" do
    owner = user!()
    library = user_library!(owner, "Roles")

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               """
               INSERT INTO public.phoenix_kit_storage_library_members (library_uuid, user_uuid, role)
               VALUES ($1::text::uuid, $2::text::uuid, 'owner')
               """,
               [library, user!()]
             )
  end

  test "re-running changes nothing and leaves no temporary constraint behind" do
    before =
      constraint_names("phoenix_kit_files") ++ constraint_names("phoenix_kit_storage_libraries")

    run(V203.up_statements("public"))
    run(V203.up_statements("public"))

    assert constraint_names("phoenix_kit_files") ++
             constraint_names("phoenix_kit_storage_libraries") == before

    refute Enum.any?(before, &String.ends_with?(&1, "_v203"))
  end

  test "down puts V202's rules back; up again restores V203's" do
    run(V203.down_statements("public"))

    assert marker() == "202"
    assert {"c", _} = constraint("phoenix_kit_files", "fk_files_user_uuid")

    assert {"r", _} =
             constraint(
               "phoenix_kit_storage_libraries",
               "phoenix_kit_storage_libraries_owner_uuid_fkey"
             )

    assert {"a", _} =
             constraint("phoenix_kit_media_folders", "phoenix_kit_media_folders_user_uuid_fkey")

    assert [] =
             query("""
             SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'phoenix_kit_storage_library_members'
             """)

    run(V203.up_statements("public"))

    assert marker() == "203"
    assert {"n", _} = constraint("phoenix_kit_files", "fk_files_user_uuid")
  end

  test "a database that ran V202 without the slug gets it (#871)" do
    user = user!()
    library = user_library!(user, "Before The Slug")

    query("DROP INDEX public.phoenix_kit_storage_libraries_owner_slug_index")
    query("ALTER TABLE public.phoenix_kit_storage_libraries DROP COLUMN slug")

    run(V203.up_statements("public"))

    assert column("phoenix_kit_storage_libraries", library, "slug") == "before-the-slug"

    assert [[_]] =
             query("""
             SELECT 1 FROM pg_indexes
             WHERE schemaname = 'public' AND indexname = 'phoenix_kit_storage_libraries_owner_slug_index'
             """)

    # The same statements V202 runs, not a copy of them.
    assert Enum.take(V203.up_statements("public"), 3) == V202.slug_statements("public")
  end
end
