defmodule PhoenixKit.API.ConfigUnreadableTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.Registry

  defmodule UnreadableRepo do
    def get_by(_schema, key: "api_disabled_tools") do
      Process.put(:settings_queries, Process.get(:settings_queries, 0) + 1)

      case Process.get(:settings_read) do
        :missing -> nil
        {:value, value} -> %PhoenixKit.Settings.Setting{value: value}
        :exit -> exit(:database_unavailable)
        _ -> raise DBConnection.ConnectionError, message: "database unavailable"
      end
    end

    def get_by(_schema, _clauses), do: nil
  end

  setup do
    previous_repo = Application.get_env(:phoenix_kit, :repo)
    previous_mode = Application.get_env(:phoenix_kit, :update_mode, false)
    Process.register(self(), UnreadableRepo)
    start_supervised!(PhoenixKit.Cache.Registry)
    start_supervised!({PhoenixKit.Cache, name: :settings})
    Application.put_env(:phoenix_kit, :repo, UnreadableRepo)
    Application.put_env(:phoenix_kit, :update_mode, false)

    on_exit(fn ->
      Application.put_env(:phoenix_kit, :repo, previous_repo)
      Application.put_env(:phoenix_kit, :update_mode, previous_mode)
    end)

    :ok
  end

  @tag capture_log: true
  test "a cold settings read that raises never re-enables hidden tools" do
    assert Config.fetch_disabled_tools() == :unreadable
    assert Registry.all_tools() == []
    assert Registry.find("system.get_identity", :admin) == {:error, :not_found}
    refute Config.admin_enabled?()
    refute Config.public_enabled?()
  end

  @tag capture_log: true
  test "a cold settings read that exits never re-enables hidden tools" do
    Process.put(:settings_read, :exit)
    assert Config.fetch_disabled_tools() == :unreadable
    assert Registry.all_tools() == []
    assert Registry.find("system.get_identity", :admin) == {:error, :not_found}
  end

  test "an explicitly empty cached list is readable even during a DB outage" do
    PhoenixKit.Cache.put(:settings, "api_disabled_tools", "")
    assert Config.fetch_disabled_tools() == {:ok, []}
    assert {:ok, _tool} = Registry.find("system.get_identity", :admin)
  end

  test "a missing row is readable and negatively cached" do
    Process.put(:settings_read, :missing)
    assert Config.fetch_disabled_tools() == {:ok, []}
    assert Config.fetch_disabled_tools() == {:ok, []}
    assert Process.get(:settings_queries) == 1
  end

  test "a failed read is not cached and recovery restores the hidden list" do
    assert Config.fetch_disabled_tools() == :unreadable
    Process.put(:settings_read, {:value, "system.get_identity"})
    assert Config.fetch_disabled_tools() == {:ok, ["system.get_identity"]}
    assert Registry.find("system.get_identity", :admin) == {:error, :not_found}
    assert Process.get(:settings_queries) == 2
  end
end
