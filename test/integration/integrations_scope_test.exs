defmodule PhoenixKit.Integration.IntegrationsScopeTest do
  @moduledoc """
  Ownership-isolation tests for personal vs system integrations. Proves the
  security model: the context — not the LiveView — enforces that a user can
  only see/read/mutate their OWN connections, and that personal rows never
  leak into system reads (mailer / send-profile selectors / consumers).
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Settings

  # Arbitrary user uuids — owner_uuid is a stored string, no FK.
  defp uid, do: UUIDv7.generate()

  # openrouter is [:system, :personal]; google is [:system] only.
  defp sys_conn(provider \\ "openrouter", name \\ "sys") do
    {:ok, %{uuid: uuid}} = Integrations.add_connection(provider, name)
    uuid
  end

  defp user_conn(user, provider \\ "openrouter", name \\ "mine") do
    {:ok, %{uuid: uuid}} = Integrations.add_connection(provider, name, nil, owner: {:user, user})
    uuid
  end

  # A connection owned by an arbitrary typed owner (e.g. a dashboard).
  defp dash_conn(dash, provider \\ "openrouter", name \\ "dash") do
    {:ok, %{uuid: uuid}} =
      Integrations.add_connection(provider, name, nil, owner: {:dashboard, dash})

    uuid
  end

  describe "birth stamps owner" do
    test "system add has no owner_uuid; personal add stamps it" do
      a = uid()
      sys = sys_conn()
      mine = user_conn(a)

      refute Map.has_key?(Settings.get_json_setting_by_uuid(sys), "owner_uuid")
      assert Settings.get_json_setting_by_uuid(mine)["owner_uuid"] == a
    end

    test "personal add of a system-only (oauth2) provider is rejected" do
      assert {:error, :scope_not_allowed} =
               Integrations.add_connection("google", "x", nil, owner: {:user, uid()})

      # system add of the same provider is fine
      assert {:ok, _} = Integrations.add_connection("google", "sysgoogle")
    end
  end

  describe "list reads are owner-scoped (default :system)" do
    test "system list excludes personal; user list is only that user's" do
      a = uid()
      b = uid()
      sys = sys_conn("openrouter", "s")
      a_uuid = user_conn(a, "openrouter", "a")
      b_uuid = user_conn(b, "openrouter", "b")

      sys_uuids = Enum.map(Integrations.list_connections("openrouter"), & &1.uuid)
      assert sys in sys_uuids
      refute a_uuid in sys_uuids
      refute b_uuid in sys_uuids

      a_list = Integrations.list_connections("openrouter", owner: {:user, a})
      assert Enum.map(a_list, & &1.uuid) == [a_uuid]

      # load_all_connections honors the same scope
      assert [%{uuid: ^b_uuid}] =
               Integrations.load_all_connections(["openrouter"], owner: {:user, b})["openrouter"]
    end
  end

  describe "IDOR read-path is closed" do
    test "get_integration_by_uuid fails closed for a cross-owner read; :any still resolves" do
      a = uid()
      mine = user_conn(a)

      # another user cannot load the decrypted row
      assert {:error, :not_configured} =
               Integrations.get_integration_by_uuid(mine, {:user, uid()})

      # system scope cannot load a personal row
      assert {:error, :not_configured} = Integrations.get_integration_by_uuid(mine, :system)

      # the owner can; and consumers (:any, the default) still resolve by pinned uuid
      assert {:ok, %{uuid: ^mine}} = Integrations.get_integration_by_uuid(mine, {:user, a})
      assert {:ok, %{uuid: ^mine}} = Integrations.get_integration_by_uuid(mine)
    end
  end

  describe "mutations fail closed on owner mismatch" do
    test "save_setup / remove / rename across owners are rejected; row survives" do
      a = uid()
      b = uid()
      a_uuid = user_conn(a, "openrouter", "a")

      # B cannot save into A's connection
      assert {:error, :not_configured} =
               Integrations.save_setup(a_uuid, %{"api_key" => "x"}, nil, owner: {:user, b})

      # system scope cannot touch a personal row
      assert {:error, :not_configured} =
               Integrations.save_setup(a_uuid, %{"api_key" => "x"}, nil, owner: :system)

      # B's remove is a no-op AND A's row survives (still resolvable by A)
      assert :ok = Integrations.remove_connection(a_uuid, nil, owner: {:user, b})
      assert {:ok, _} = Integrations.get_integration_by_uuid(a_uuid, {:user, a})

      # A's own mutation works
      assert {:ok, _} =
               Integrations.save_setup(a_uuid, %{"api_key" => "real"}, nil, owner: {:user, a})

      assert {:ok, %{"api_key" => "real"}} = Integrations.get_credentials(a_uuid)
    end
  end

  describe "owner_uuid is immutable / write-once" do
    test "save_setup cannot overwrite owner_uuid via attrs" do
      a = uid()
      mine = user_conn(a)

      {:ok, _} =
        Integrations.save_setup(mine, %{"api_key" => "k", "owner_uuid" => uid()}, nil,
          owner: {:user, a}
        )

      assert Settings.get_json_setting_by_uuid(mine)["owner_uuid"] == a
    end

    test "disconnect preserves owner (does not convert personal → system)" do
      a = uid()
      mine = user_conn(a)
      {:ok, _} = Integrations.save_setup(mine, %{"api_key" => "k"}, nil, owner: {:user, a})

      :ok = Integrations.disconnect(mine, nil, owner: {:user, a})

      assert Settings.get_json_setting_by_uuid(mine)["owner_uuid"] == a
      # still owned by A afterwards
      assert {:ok, _} = Integrations.get_integration_by_uuid(mine, {:user, a})
    end
  end

  describe "provider scopes" do
    test "for_scope filters correctly" do
      personal = Enum.map(Providers.for_scope(:personal), & &1.key)
      system = Enum.map(Providers.for_scope(:system), & &1.key)

      assert "openrouter" in personal
      refute "google" in personal

      assert "google" in system
      assert "openrouter" in system
    end

    test "scopes_of defaults to [:system] for an unknown provider" do
      assert Providers.scopes_of("does_not_exist") == [:system]
    end
  end

  describe "get_credentials owner scoping" do
    test "owner-agnostic by default; scoped call rejects a foreign owner" do
      a = uid()
      mine = user_conn(a)
      {:ok, _} = Integrations.save_setup(mine, %{"api_key" => "k"}, nil, owner: {:user, a})

      # consumer default (:any) resolves by pinned uuid
      assert {:ok, %{"api_key" => "k"}} = Integrations.get_credentials(mine)
      # owner-scoped call by the owner works
      assert {:ok, _} = Integrations.get_credentials(mine, owner: {:user, a})
      # owner-scoped call by a different user is rejected
      assert {:error, :deleted} = Integrations.get_credentials(mine, owner: {:user, uid()})
    end

    test "bare provider:name lookup defaults to system (never first-matches a personal row)" do
      a = uid()
      _mine = user_conn(a, "openrouter", "shared")

      # no system row named "shared" exists → system-scoped lookup misses
      assert {:error, :not_found} =
               Integrations.find_uuid_by_provider_name("openrouter:shared")
    end
  end

  describe "custom owner types (dashboard / team / …)" do
    test "an arbitrary typed owner births, isolates, and reads back" do
      d = uid()
      conn = dash_conn(d)

      # stored as owner_type + owner_uuid
      stored = Settings.get_json_setting_by_uuid(conn)
      assert stored["owner_type"] == "dashboard"
      assert stored["owner_uuid"] == d

      # the dashboard scope reads + lists it
      assert {:ok, %{uuid: ^conn}} = Integrations.get_integration_by_uuid(conn, {:dashboard, d})

      assert [%{uuid: ^conn}] =
               Integrations.list_connections("openrouter", owner: {:dashboard, d})

      # system and user scopes do NOT see it
      refute conn in Enum.map(Integrations.list_connections("openrouter"), & &1.uuid)
      assert {:error, :not_configured} = Integrations.get_integration_by_uuid(conn, :system)
      assert {:error, :not_configured} = Integrations.get_integration_by_uuid(conn, {:user, d})
    end

    test "owner TYPE discriminates even when the id collides with a user id" do
      id = uid()
      dash = dash_conn(id)

      # a user whose uuid equals the dashboard's id still can't reach it
      assert {:error, :not_configured} = Integrations.get_integration_by_uuid(dash, {:user, id})
      assert {:ok, _} = Integrations.get_integration_by_uuid(dash, {:dashboard, id})
      assert Integrations.list_connections("openrouter", owner: {:user, id}) == []
    end

    test "mutations are owner-type-scoped" do
      d = uid()
      conn = dash_conn(d)

      # same-id user cannot mutate the dashboard's connection
      assert {:error, :not_configured} =
               Integrations.save_setup(conn, %{"api_key" => "x"}, nil, owner: {:user, d})

      # the dashboard scope can
      assert {:ok, _} =
               Integrations.save_setup(conn, %{"api_key" => "real"}, nil, owner: {:dashboard, d})

      assert {:ok, %{"api_key" => "real"}} = Integrations.get_credentials(conn)
    end
  end

  describe "back-compat: pre-typed rows (owner_uuid, no owner_type)" do
    test "a legacy owned row reads as a user owner" do
      u = uid()
      conn = user_conn(u)

      # simulate a row written before owner_type existed
      legacy = Map.delete(Settings.get_json_setting_by_uuid(conn), "owner_type")
      {:ok, _} = Settings.update_json_setting(conn, legacy)
      refute Map.has_key?(Settings.get_json_setting_by_uuid(conn), "owner_type")

      # still resolves as {:user, u} via both the row read and the list read
      assert {:ok, %{uuid: ^conn}} = Integrations.get_integration_by_uuid(conn, {:user, u})
      assert [%{uuid: ^conn}] = Integrations.list_connections("openrouter", owner: {:user, u})

      # and never as system
      assert {:error, :not_configured} = Integrations.get_integration_by_uuid(conn, :system)
    end
  end
end
