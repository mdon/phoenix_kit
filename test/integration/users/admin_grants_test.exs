defmodule PhoenixKit.Integration.Users.AdminGrantsTest do
  # async: false — the grants run in their own process, so the sandbox is
  # shared; a trigger on the permissions table makes one key's grant fail.
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Permissions.AdminGrants
  alias PhoenixKit.Users.Roles

  @key "languages"
  @flag "auto_granted_perm:languages"
  @media_flag "media_sub_permissions_backfilled"

  setup do
    admin_uuid = Roles.get_role_by_name("Admin").uuid

    Repo.query!("DELETE FROM phoenix_kit_role_permissions WHERE module_key = $1", [@key])
    Repo.query!("DELETE FROM phoenix_kit_settings WHERE key = $1", [@flag])
    Repo.query!("DELETE FROM phoenix_kit_settings WHERE key = $1", [@media_flag])

    Repo.query!(
      "DELETE FROM phoenix_kit_role_permissions WHERE module_key IN ('media.view_all', 'media.manage')"
    )

    # What a database error on this one key looks like: the insert raises.
    Repo.query!("""
    CREATE FUNCTION pk_block_grant() RETURNS trigger AS $$
    BEGIN
      IF NEW.module_key IN ('languages', 'media.view_all') THEN
        RAISE EXCEPTION 'simulated database failure';
      END IF;
      RETURN NEW;
    END $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER pk_block_grant BEFORE INSERT ON phoenix_kit_role_permissions
    FOR EACH ROW EXECUTE FUNCTION pk_block_grant()
    """)

    {:ok, admin_uuid: admin_uuid}
  end

  defp recover do
    Repo.query!("DROP TRIGGER pk_block_grant ON phoenix_kit_role_permissions")
  end

  defp flag, do: Settings.get_setting(@flag)

  describe "a grant that hits a database error" do
    test "returns the error, logs it with the key and leaves the flag unset", %{
      admin_uuid: admin_uuid
    } do
      log =
        capture_log(fn ->
          assert {:error, _} = Permissions.auto_grant_to_admin_roles(@key)
        end)

      assert log =~ "[error]"
      assert log =~ ~s("languages")
      assert flag() != "true"
      refute @key in Permissions.get_permissions_for_role(admin_uuid)
    end

    test "is granted, and flagged, once the database recovers", %{admin_uuid: admin_uuid} do
      capture_log(fn -> assert {:error, _} = Permissions.auto_grant_to_admin_roles(@key) end)

      recover()

      assert :ok = Permissions.auto_grant_to_admin_roles(@key)
      assert @key in Permissions.get_permissions_for_role(admin_uuid)
      assert flag() == "true"
    end

    test "makes the sweep return the failed keys" do
      capture_log(fn ->
        assert {:error, failed} = Permissions.auto_grant_new_keys_to_admin()
        assert {@key, _} = List.keyfind(failed, @key, 0)
      end)

      recover()
      assert :ok = Permissions.auto_grant_new_keys_to_admin()
    end
  end

  describe "AdminGrants" do
    defp start_grants(opts) do
      opts = Keyword.merge([name: :test_admin_grants, sync_registry: false], opts)
      start_supervised!({AdminGrants, opts})
      opts[:name]
    end

    test "retries a failed key until it is granted, and await returns :ok", %{
      admin_uuid: admin_uuid
    } do
      capture_log(fn ->
        server = start_grants(retry_base_ms: 20, max_attempts: 50)
        # The first pass is over (and failed) before the wait is judged.
        wait_initial(server)

        # Still failing: the wait runs out.
        assert {:error, :timeout} = AdminGrants.await(100, server)
        refute @key in Permissions.get_permissions_for_role(admin_uuid)
        assert flag() != "true"

        recover()

        assert :ok = AdminGrants.await(5_000, server)
      end)

      assert @key in Permissions.get_permissions_for_role(admin_uuid)
      assert flag() == "true"
    end

    test "a failure reported after startup is picked up by the running server", %{
      admin_uuid: admin_uuid
    } do
      recover()
      server = start_grants(retry_base_ms: 20)
      assert :ok = AdminGrants.await(5_000, server)

      Repo.query!("DELETE FROM phoenix_kit_role_permissions WHERE module_key = $1", [@key])
      Repo.query!("DELETE FROM phoenix_kit_settings WHERE key = $1", [@flag])
      AdminGrants.report_failure(@key, server)

      assert :ok = AdminGrants.await(5_000, server)
      assert @key in Permissions.get_permissions_for_role(admin_uuid)
    end

    test "gives up after max_attempts and says which keys are missing" do
      log =
        capture_log(fn ->
          server = start_grants(retry_base_ms: 5, max_attempts: 2)
          assert {:error, {:failed, keys}} = AdminGrants.await(5_000, server)
          assert @key in keys
        end)

      assert log =~ "Giving up"
      assert flag() != "true"
    end

    defp wait_initial(server) do
      Enum.find(1..200, fn _ ->
        initial? = :sys.get_state(server).initial_done?
        unless initial?, do: Process.sleep(10)
        initial?
      end) || flunk("the first pass never finished")
    end

    test "the pause between retries doubles" do
      capture_log(fn ->
        server = start_grants(retry_base_ms: 1_000, max_attempts: 5)
        wait_initial(server)

        first = Process.read_timer(:sys.get_state(server).timer)
        assert first in 1..1_000

        send(server, :retry)
        second = Process.read_timer(:sys.get_state(server).timer)
        assert second > 1_000 and second <= 2_000
      end)
    end

    test "a failure reported through the dashboard registry path is retried", %{
      admin_uuid: admin_uuid
    } do
      capture_log(fn ->
        start_supervised!({AdminGrants, retry_base_ms: 20, sync_registry: false})
        wait_initial(AdminGrants)
        recover()

        # Not the sweep: the tab registry granting the key of a core tab.
        Repo.query!("DELETE FROM phoenix_kit_role_permissions WHERE module_key = $1", [@key])
        Repo.query!("DELETE FROM phoenix_kit_settings WHERE key = $1", [@flag])

        Repo.query!("""
        CREATE TRIGGER pk_block_grant BEFORE INSERT ON phoenix_kit_role_permissions
        FOR EACH ROW EXECUTE FUNCTION pk_block_grant()
        """)

        PhoenixKit.Dashboard.Registry.auto_register_custom_permission(%{permission: @key})
        assert {:error, :timeout} = AdminGrants.await(100)

        recover()
        assert :ok = AdminGrants.await(5_000)
      end)

      assert @key in Permissions.get_permissions_for_role(admin_uuid)
    end

    test "a failed media backfill is returned, retried and flagged only on success" do
      capture_log(fn ->
        assert {:error, _} = Permissions.backfill_media_sub_permissions()
        assert Settings.get_setting(@media_flag) != "true"

        server = start_grants(retry_base_ms: 20, max_attempts: 50)
        assert {:error, :timeout} = AdminGrants.await(100, server)
        assert :media_subs in :sys.get_state(server).pending

        recover()
        assert :ok = AdminGrants.await(5_000, server)
      end)

      assert Settings.get_setting(@media_flag) == "true"
    end

    test "a missing table is an expected :ok, not an error" do
      recover()
      Repo.query!("ALTER TABLE phoenix_kit_settings RENAME TO pk_settings_gone")

      log =
        capture_log(fn ->
          assert :ok = Permissions.auto_grant_to_admin_roles(@key)
          assert :ok = Permissions.backfill_media_sub_permissions()
        end)

      refute log =~ "[error]"
    end

    test "a saved flag that comes back as an error fails the grant" do
      recover()

      Repo.query!("""
      CREATE FUNCTION pk_block_flag() RETURNS trigger AS $$
      BEGIN
        IF NEW.key = 'auto_granted_perm:languages' THEN
          RAISE EXCEPTION 'simulated flag failure';
        END IF;
        RETURN NEW;
      END $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER pk_block_flag BEFORE INSERT OR UPDATE ON phoenix_kit_settings
      FOR EACH ROW EXECUTE FUNCTION pk_block_flag()
      """)

      capture_log(fn -> assert {:error, _} = Permissions.auto_grant_to_admin_roles(@key) end)
      assert flag() != "true"
    end

    test "only database errors are retried" do
      refute Permissions.retriable_grant_error?(%Ecto.Changeset{valid?: false})
      refute Permissions.retriable_grant_error?(:role_not_found)
      refute Permissions.retriable_grant_error?({:no_owner, %DBConnection.OwnershipError{}})
      assert Permissions.retriable_grant_error?(%Postgrex.Error{})
      assert Permissions.retriable_grant_error?({:exit, :noproc})
    end

    test "await returns an error, not an exit, when the server dies while waiting" do
      capture_log(fn ->
        server = start_grants(retry_base_ms: 5_000, max_attempts: 5)
        wait_initial(server)
        pid = Process.whereis(server)

        task = Task.async(fn -> AdminGrants.await(5_000, server) end)
        Process.sleep(50)
        Process.exit(pid, :kill)

        assert {:error, {:exit, _}} = Task.await(task)
      end)
    end

    test "the dashboard registry wait is :ok when nothing is running" do
      assert :ok = PhoenixKit.Dashboard.Registry.await_initialized(10)
    end

    test "await returns :ok when no server is running" do
      assert :ok = AdminGrants.await(10, :no_such_admin_grants)
    end
  end
end
