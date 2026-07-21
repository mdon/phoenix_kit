defmodule PhoenixKit.Migrations.Postgres.V156Test do
  @moduledoc """
  Tests V156's schema state — legacy newsletters lists migrated into CRM,
  then dropped.

  V156.up/down can't be invoked outside an `Ecto.Migrator` runner — same
  constraint as V145Test/V152Test/V155Test. The schema is verified at
  boot: `test_helper.exs` runs `ensure_current/2` (now through V156)
  before any test, so the "gone" describes below pin the post-V156 shape.

  The full chain always starts from a fresh V1 install with nothing in
  `phoenix_kit_newsletters_lists`/`..._list_members` for V156 to actually
  migrate (same constraint V152Test's "copy semantics" section documents
  for the send-profiles move) — by the time any test runs, those tables
  are already gone and there was never legacy data in them to begin with.
  What CAN be pinned directly: the post-migration absence of the old
  tables/column/FK (below), and — for the actual copy/link/re-point
  LOGIC — re-running the *exact same* SQL V156.up/1 uses against staged
  temp tables shaped like the old ones, joined against the real (still
  live) `phoenix_kit_users`/`phoenix_kit_crm_*` tables. A change to
  V156.up/1's SQL that isn't mirrored here is exactly the regression this
  file exists to catch.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth.User

  defp column(table, column) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT data_type, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    case rows do
      [[data_type, is_nullable, default]] ->
        %{type: data_type, nullable: is_nullable, default: default}

      [] ->
        nil
    end
  end

  defp index_exists?(name) do
    %{rows: [[exists]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = $1)", [name])

    exists
  end

  defp table_exists?(name) do
    %{rows: [[exists]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = $1)", [name])

    exists
  end

  defp constraint_exists?(name) do
    %{rows: [[exists]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = $1)", [name])

    exists
  end

  defp insert_user!(attrs \\ %{}) do
    base = %{email: "v156-test-#{System.unique_integer([:positive])}@example.com"}

    %User{}
    |> User.guest_user_changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  defp insert_crm_list!(attrs \\ %{}) do
    base = %{
      name: "Base list",
      slug: "v156-crm-list-#{System.unique_integer([:positive])}"
    }

    attrs = Map.merge(base, attrs)

    %{rows: [[uuid]]} =
      Repo.query!(
        "INSERT INTO phoenix_kit_crm_lists (name, slug) VALUES ($1, $2) RETURNING uuid",
        [attrs.name, attrs.slug]
      )

    %{uuid: uuid, name: attrs.name, slug: attrs.slug}
  end

  defp insert_crm_contact!(attrs) do
    user_uuid_bin =
      case Map.get(attrs, :user_uuid) do
        nil -> nil
        uuid_string -> Ecto.UUID.dump!(uuid_string)
      end

    %{rows: [[uuid]]} =
      Repo.query!(
        "INSERT INTO phoenix_kit_crm_contacts (name, email, user_uuid) VALUES ($1, $2, $3) RETURNING uuid",
        [Map.get(attrs, :name, "Contact"), Map.fetch!(attrs, :email), user_uuid_bin]
      )

    uuid
  end

  # Mirrors V156.up/1's own list-copy SQL exactly (see migrate_lists/1).
  defp copy_staged_lists_to_crm do
    Repo.query!("""
    INSERT INTO phoenix_kit_crm_lists (name, slug, description, status, subscribable)
    SELECT l.name, l.slug, l.description, l.status, true
    FROM staged_newsletters_lists l
    WHERE NOT EXISTS (
      SELECT 1 FROM phoenix_kit_crm_lists cl WHERE cl.slug = l.slug
    )
    """)
  end

  # Mirrors create_contacts_for_migrating_users/1 + link_contacts_to_existing_users/1.
  defp create_and_link_contacts do
    Repo.query!("""
    INSERT INTO phoenix_kit_crm_contacts (name, email)
    SELECT
      COALESCE(NULLIF(TRIM(CONCAT_WS(' ', u.first_name, u.last_name)), ''), u.email::text),
      u.email
    FROM phoenix_kit_users u
    WHERE u.uuid IN (SELECT DISTINCT user_uuid FROM staged_newsletters_list_members)
      AND NOT EXISTS (
        SELECT 1 FROM phoenix_kit_crm_contacts c WHERE c.email = u.email
      )
    """)

    Repo.query!("""
    UPDATE phoenix_kit_crm_contacts c
    SET user_uuid = u.uuid
    FROM phoenix_kit_users u
    WHERE c.user_uuid IS NULL
      AND c.email = u.email
      AND u.uuid IN (SELECT DISTINCT user_uuid FROM staged_newsletters_list_members)
      AND c.uuid = (
        SELECT c2.uuid FROM phoenix_kit_crm_contacts c2
        WHERE c2.email = u.email AND c2.user_uuid IS NULL
        ORDER BY c2.inserted_at ASC, c2.uuid ASC
        LIMIT 1
      )
    """)
  end

  # Mirrors migrate_memberships/1.
  defp copy_staged_memberships_to_crm do
    Repo.query!("""
    INSERT INTO phoenix_kit_crm_list_members
      (list_uuid, contact_uuid, email, status, subscribed_at, unsubscribed_at, source)
    SELECT
      cl.uuid,
      c.uuid,
      c.email,
      CASE m.status
        WHEN 'active' THEN 'subscribed'
        WHEN 'unsubscribed' THEN 'removed'
        ELSE 'removed'
      END,
      m.subscribed_at,
      m.unsubscribed_at,
      'import'
    FROM staged_newsletters_list_members m
    JOIN staged_newsletters_lists l ON l.uuid = m.list_uuid
    JOIN phoenix_kit_crm_lists cl ON cl.slug = l.slug
    JOIN phoenix_kit_crm_contacts c ON c.user_uuid = m.user_uuid
    ON CONFLICT DO NOTHING
    """)
  end

  # Mirrors recount_migrated_lists/1, scoped by the given slugs (the real
  # version scopes by every slug still in phoenix_kit_newsletters_lists —
  # tests scope explicitly since that table no longer exists to select from).
  defp recount(slugs) do
    Repo.query!(
      """
      UPDATE phoenix_kit_crm_lists cl
      SET subscriber_count = (
        SELECT COUNT(*) FROM phoenix_kit_crm_list_members m
        WHERE m.list_uuid = cl.uuid AND m.status = 'subscribed'
      )
      WHERE cl.slug = ANY($1)
      """,
      [slugs]
    )
  end

  defp stage_lists_and_members_tables do
    Repo.query!("""
    CREATE TEMP TABLE staged_newsletters_lists (
      uuid UUID PRIMARY KEY,
      name VARCHAR(255) NOT NULL,
      slug VARCHAR(255) NOT NULL,
      description TEXT,
      status VARCHAR(20) NOT NULL DEFAULT 'active'
    ) ON COMMIT DROP
    """)

    Repo.query!("""
    CREATE TEMP TABLE staged_newsletters_list_members (
      uuid UUID PRIMARY KEY,
      user_uuid UUID NOT NULL,
      list_uuid UUID NOT NULL,
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      subscribed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      unsubscribed_at TIMESTAMPTZ
    ) ON COMMIT DROP
    """)
  end

  defp uuid!, do: Ecto.UUID.generate() |> Ecto.UUID.dump!()

  defp stage_broadcasts_table do
    Repo.query!("""
    CREATE TEMP TABLE staged_broadcasts (
      uuid UUID PRIMARY KEY,
      source_type VARCHAR(20) NOT NULL,
      list_uuid UUID,
      crm_list_uuid UUID,
      source_params JSONB NOT NULL DEFAULT '{}'::jsonb
    ) ON COMMIT DROP
    """)
  end

  # Mirrors up_repoint_broadcasts/1's two UPDATEs exactly.
  defp repoint_staged_broadcasts do
    Repo.query!("""
    UPDATE staged_broadcasts b
    SET source_type = 'crm_list', crm_list_uuid = cl.uuid
    FROM staged_newsletters_lists l
    JOIN phoenix_kit_crm_lists cl ON cl.slug = l.slug
    WHERE b.list_uuid = l.uuid
      AND b.source_type = 'newsletters_list'
    """)

    Repo.query!("""
    UPDATE staged_broadcasts b
    SET source_params = b.source_params || jsonb_build_object('legacy_list_uuid', b.list_uuid::text)
    WHERE b.source_type = 'newsletters_list' AND b.list_uuid IS NOT NULL
    """)
  end

  describe "phoenix_kit_newsletters_lists / _list_members are gone" do
    test "both legacy tables no longer exist" do
      refute table_exists?("phoenix_kit_newsletters_lists")
      refute table_exists?("phoenix_kit_newsletters_list_members")
    end
  end

  describe "phoenix_kit_newsletters_broadcasts.list_uuid is gone" do
    test "the column, its FK, and its index are all gone" do
      refute column("phoenix_kit_newsletters_broadcasts", "list_uuid")
      refute constraint_exists?("fk_newsletters_broadcasts_list")
      refute index_exists?("idx_newsletters_broadcasts_list")
    end
  end

  describe "list migration semantics (mirrors V156.up's list copy)" do
    test "copies name/slug/description/status verbatim and sets subscribable true" do
      stage_lists_and_members_tables()
      list_uuid = uuid!()
      slug = "v156-archived-list-#{System.unique_integer([:positive])}"

      Repo.query!(
        "INSERT INTO staged_newsletters_lists (uuid, name, slug, description, status) VALUES ($1, $2, $3, $4, $5)",
        [list_uuid, "Old Announcements", slug, "Kept for history", "archived"]
      )

      copy_staged_lists_to_crm()

      %{rows: [[name, description, status, subscribable]]} =
        Repo.query!(
          "SELECT name, description, status, subscribable FROM phoenix_kit_crm_lists WHERE slug = $1",
          [slug]
        )

      assert name == "Old Announcements"
      assert description == "Kept for history"
      # Copied verbatim, not defaulted — proves the source value survives
      # even when it differs from crm_lists.status's own default.
      assert status == "archived"
      assert subscribable == true
    end

    test "reuses an existing CRM list with the same slug instead of duplicating it" do
      slug = "v156-shared-slug-#{System.unique_integer([:positive])}"
      %{uuid: existing_uuid} = insert_crm_list!(%{name: "Already here", slug: slug})

      stage_lists_and_members_tables()

      Repo.query!(
        "INSERT INTO staged_newsletters_lists (uuid, name, slug) VALUES ($1, $2, $3)",
        [uuid!(), "Would-be duplicate", slug]
      )

      copy_staged_lists_to_crm()

      %{rows: rows} =
        Repo.query!("SELECT uuid, name FROM phoenix_kit_crm_lists WHERE slug = $1", [slug])

      assert [[found_uuid, "Already here"]] = rows
      assert found_uuid == existing_uuid
    end
  end

  describe "contact create+link semantics (mirrors V156.up's contact steps)" do
    test "creates a contact for a migrating user and links it directly — never mints a user" do
      user = insert_user!(%{first_name: "Ada", last_name: "Lovelace"})
      stage_lists_and_members_tables()
      list_uuid = uuid!()

      Repo.query!(
        "INSERT INTO staged_newsletters_list_members (uuid, user_uuid, list_uuid) VALUES ($1, $2, $3)",
        [uuid!(), Ecto.UUID.dump!(user.uuid), list_uuid]
      )

      user_count_before = Repo.aggregate(User, :count)

      create_and_link_contacts()

      assert Repo.aggregate(User, :count) == user_count_before

      %{rows: [[name, email, linked_user_uuid]]} =
        Repo.query!(
          "SELECT name, email, user_uuid FROM phoenix_kit_crm_contacts WHERE user_uuid = $1",
          [Ecto.UUID.dump!(user.uuid)]
        )

      assert name == "Ada Lovelace"
      assert email == user.email
      assert linked_user_uuid == Ecto.UUID.dump!(user.uuid)
    end

    test "falls back to the user's email as the contact name when no first/last name is set" do
      user = insert_user!()
      stage_lists_and_members_tables()

      Repo.query!(
        "INSERT INTO staged_newsletters_list_members (uuid, user_uuid, list_uuid) VALUES ($1, $2, $3)",
        [uuid!(), Ecto.UUID.dump!(user.uuid), uuid!()]
      )

      create_and_link_contacts()

      %{rows: [[name]]} =
        Repo.query!("SELECT name FROM phoenix_kit_crm_contacts WHERE user_uuid = $1", [
          Ecto.UUID.dump!(user.uuid)
        ])

      assert name == user.email
    end

    test "reuses an already-existing unlinked contact with the same email instead of duplicating" do
      user = insert_user!()
      existing_contact_uuid = insert_crm_contact!(%{email: user.email})

      stage_lists_and_members_tables()

      Repo.query!(
        "INSERT INTO staged_newsletters_list_members (uuid, user_uuid, list_uuid) VALUES ($1, $2, $3)",
        [uuid!(), Ecto.UUID.dump!(user.uuid), uuid!()]
      )

      create_and_link_contacts()

      %{rows: rows} =
        Repo.query!("SELECT uuid, user_uuid FROM phoenix_kit_crm_contacts WHERE email = $1", [
          user.email
        ])

      assert [[found_uuid, linked_user_uuid]] = rows
      assert found_uuid == existing_contact_uuid
      assert linked_user_uuid == Ecto.UUID.dump!(user.uuid)
    end

    test "picks only one of several duplicate unlinked contacts sharing an email — never violates the unique user_uuid index" do
      user = insert_user!()
      contact_a = insert_crm_contact!(%{email: user.email})
      contact_b = insert_crm_contact!(%{email: user.email})

      stage_lists_and_members_tables()

      Repo.query!(
        "INSERT INTO staged_newsletters_list_members (uuid, user_uuid, list_uuid) VALUES ($1, $2, $3)",
        [uuid!(), Ecto.UUID.dump!(user.uuid), uuid!()]
      )

      create_and_link_contacts()

      %{rows: rows} =
        Repo.query!(
          "SELECT uuid, user_uuid FROM phoenix_kit_crm_contacts WHERE uuid = ANY($1) ORDER BY uuid",
          [[contact_a, contact_b]]
        )

      linked = Enum.filter(rows, fn [_uuid, user_uuid] -> user_uuid != nil end)
      assert length(linked) == 1
      assert [[_uuid, linked_user_uuid]] = linked
      assert linked_user_uuid == Ecto.UUID.dump!(user.uuid)
    end
  end

  describe "membership migration semantics (mirrors V156.up's membership copy)" do
    test "maps active/unsubscribed to subscribed/removed, preserving the original dates verbatim" do
      active_user = insert_user!()
      unsubscribed_user = insert_user!()
      crm_list = insert_crm_list!()

      active_contact =
        insert_crm_contact!(%{email: active_user.email, user_uuid: active_user.uuid})

      unsub_contact =
        insert_crm_contact!(%{email: unsubscribed_user.email, user_uuid: unsubscribed_user.uuid})

      stage_lists_and_members_tables()
      legacy_list_uuid = uuid!()

      Repo.query!(
        "INSERT INTO staged_newsletters_lists (uuid, name, slug) VALUES ($1, $2, $3)",
        [legacy_list_uuid, crm_list.name, crm_list.slug]
      )

      Repo.query!(
        """
        INSERT INTO staged_newsletters_list_members
          (uuid, user_uuid, list_uuid, status, subscribed_at, unsubscribed_at)
        VALUES ($1, $2, $3, 'active', '2026-01-15T10:00:00Z', NULL)
        """,
        [uuid!(), Ecto.UUID.dump!(active_user.uuid), legacy_list_uuid]
      )

      Repo.query!(
        """
        INSERT INTO staged_newsletters_list_members
          (uuid, user_uuid, list_uuid, status, subscribed_at, unsubscribed_at)
        VALUES ($1, $2, $3, 'unsubscribed', '2026-01-10T08:00:00Z', '2026-02-01T09:30:00Z')
        """,
        [uuid!(), Ecto.UUID.dump!(unsubscribed_user.uuid), legacy_list_uuid]
      )

      copy_staged_memberships_to_crm()

      %{rows: [[status, subscribed_at, unsubscribed_at, source]]} =
        Repo.query!(
          "SELECT status, subscribed_at, unsubscribed_at, source FROM phoenix_kit_crm_list_members WHERE list_uuid = $1 AND contact_uuid = $2",
          [crm_list.uuid, active_contact]
        )

      assert status == "subscribed"
      assert subscribed_at == ~U[2026-01-15 10:00:00Z]
      assert unsubscribed_at == nil
      assert source == "import"

      %{rows: [[status2, subscribed_at2, unsubscribed_at2]]} =
        Repo.query!(
          "SELECT status, subscribed_at, unsubscribed_at FROM phoenix_kit_crm_list_members WHERE list_uuid = $1 AND contact_uuid = $2",
          [crm_list.uuid, unsub_contact]
        )

      assert status2 == "removed"
      assert subscribed_at2 == ~U[2026-01-10 08:00:00Z]
      assert unsubscribed_at2 == ~U[2026-02-01 09:30:00Z]
    end

    test "recount sets subscriber_count to the number of subscribed members only" do
      crm_list = insert_crm_list!()
      user_a = insert_user!()
      user_b = insert_user!()
      user_c = insert_user!()
      contact_a = insert_crm_contact!(%{email: user_a.email, user_uuid: user_a.uuid})
      contact_b = insert_crm_contact!(%{email: user_b.email, user_uuid: user_b.uuid})
      contact_c = insert_crm_contact!(%{email: user_c.email, user_uuid: user_c.uuid})

      Repo.query!(
        "INSERT INTO phoenix_kit_crm_list_members (list_uuid, contact_uuid, status) VALUES ($1, $2, 'subscribed'), ($1, $3, 'subscribed'), ($1, $4, 'removed')",
        [crm_list.uuid, contact_a, contact_b, contact_c]
      )

      recount([crm_list.slug])

      %{rows: [[subscriber_count]]} =
        Repo.query!("SELECT subscriber_count FROM phoenix_kit_crm_lists WHERE uuid = $1", [
          crm_list.uuid
        ])

      assert subscriber_count == 2
    end

    test "ON CONFLICT DO NOTHING — a pre-existing membership for (list, contact) is left untouched" do
      crm_list = insert_crm_list!()
      user = insert_user!()
      contact = insert_crm_contact!(%{email: user.email, user_uuid: user.uuid})

      Repo.query!(
        "INSERT INTO phoenix_kit_crm_list_members (list_uuid, contact_uuid, status) VALUES ($1, $2, 'removed')",
        [crm_list.uuid, contact]
      )

      stage_lists_and_members_tables()
      legacy_list_uuid = uuid!()

      Repo.query!(
        "INSERT INTO staged_newsletters_lists (uuid, name, slug) VALUES ($1, $2, $3)",
        [legacy_list_uuid, crm_list.name, crm_list.slug]
      )

      Repo.query!(
        "INSERT INTO staged_newsletters_list_members (uuid, user_uuid, list_uuid, status) VALUES ($1, $2, $3, 'active')",
        [uuid!(), Ecto.UUID.dump!(user.uuid), legacy_list_uuid]
      )

      copy_staged_memberships_to_crm()

      %{rows: rows} =
        Repo.query!(
          "SELECT status FROM phoenix_kit_crm_list_members WHERE list_uuid = $1 AND contact_uuid = $2",
          [crm_list.uuid, contact]
        )

      # Still exactly one row, still 'removed' — the migration's INSERT
      # did not overwrite the pre-existing membership's status.
      assert rows == [["removed"]]
    end
  end

  describe "broadcast re-point semantics (mirrors V156.up's UPDATE)" do
    test "a broadcast whose list_uuid matches a migrated list is re-pointed to crm_list" do
      stage_lists_and_members_tables()
      stage_broadcasts_table()

      crm_list = insert_crm_list!()
      legacy_list_uuid = uuid!()

      Repo.query!(
        "INSERT INTO staged_newsletters_lists (uuid, name, slug) VALUES ($1, $2, $3)",
        [legacy_list_uuid, crm_list.name, crm_list.slug]
      )

      broadcast_uuid = uuid!()

      Repo.query!(
        "INSERT INTO staged_broadcasts (uuid, source_type, list_uuid) VALUES ($1, 'newsletters_list', $2)",
        [broadcast_uuid, legacy_list_uuid]
      )

      repoint_staged_broadcasts()

      %{rows: [[source_type, crm_list_uuid]]} =
        Repo.query!("SELECT source_type, crm_list_uuid FROM staged_broadcasts WHERE uuid = $1", [
          broadcast_uuid
        ])

      assert source_type == "crm_list"
      assert crm_list_uuid == crm_list.uuid
    end

    test "orphan guard stashes an unmatched list_uuid into source_params instead of losing it" do
      stage_lists_and_members_tables()
      stage_broadcasts_table()

      orphan_list_uuid = uuid!()
      broadcast_uuid = uuid!()

      Repo.query!(
        "INSERT INTO staged_broadcasts (uuid, source_type, list_uuid) VALUES ($1, 'newsletters_list', $2)",
        [broadcast_uuid, orphan_list_uuid]
      )

      repoint_staged_broadcasts()

      %{rows: [[source_type, source_params]]} =
        Repo.query!(
          "SELECT source_type, source_params FROM staged_broadcasts WHERE uuid = $1",
          [broadcast_uuid]
        )

      # Nothing matched — stays at the old flavor, but the uuid it would
      # otherwise have lost when the column is dropped is preserved.
      assert source_type == "newsletters_list"
      assert %{"legacy_list_uuid" => stashed} = source_params
      assert {:ok, ^orphan_list_uuid} = Ecto.UUID.dump(stashed)
    end
  end

  describe "version marker" do
    test "phoenix_kit table comment is at or past V156" do
      %{rows: [[comment]]} =
        Repo.query!("SELECT obj_description('phoenix_kit'::regclass, 'pg_class')")

      # >= rather than ==: pinning the exact latest version breaks this
      # test every time a NEWER migration ships.
      assert String.to_integer(comment) >= 156
    end
  end
end
