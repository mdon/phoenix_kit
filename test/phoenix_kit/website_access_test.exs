defmodule PhoenixKit.WebsiteAccessTest do
  @moduledoc "The facade: the feature list and its switches."
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Settings
  alias PhoenixKit.WebsiteAccess
  alias PhoenixKit.WebsiteAccess.{AllowedAddresses, Gate, Redirect}

  setup do
    reset_features()
    Settings.update_setting(Gate.password_key(), "")
    Settings.update_setting(Redirect.url_key(), "")
    Settings.update_setting(AllowedAddresses.key(), "")
    Maintenance.clear_schedule()
    :ok
  end

  test "the feature list, in page order, all off on a live site" do
    keys = Enum.map(WebsiteAccess.features(), & &1.key)
    assert keys == [:gate, :redirect, :maintenance, :no_index, :allowed_addresses]
    refute Enum.any?(WebsiteAccess.features(), & &1.on?)
    assert Enum.all?(WebsiteAccess.features(), &is_binary(&1.explanation))
  end

  test "a switched-on feature that is not ready says what it needs" do
    {:ok, _} = WebsiteAccess.set(:gate, true, [])
    gate = feature(:gate)
    assert gate.switched_on?
    refute gate.on?
    refute gate.ready?
    assert gate.needs =~ "password"

    {:ok, _} = Gate.set_password("x")
    assert feature(:gate).on?
    assert feature(:gate).needs == nil
  end

  test "the closed page's switch follows the real state, so a scheduled window can be opened by hand" do
    :ok = Maintenance.update_schedule(nil, DateTime.add(DateTime.utc_now(), 3600, :second))
    refute feature(:maintenance).on?

    :ok = Maintenance.update_schedule(DateTime.add(DateTime.utc_now(), -10, :second), nil)
    assert feature(:maintenance).on?
    assert feature(:maintenance).switched_on?, "the switch shows on, not the manual flag"

    {:ok, _} = WebsiteAccess.set(:maintenance, false, [])
    refute Maintenance.active?()
    assert Maintenance.get_scheduled_start() == nil, "switching off also clears the window"
  end

  test "a feature without a switch says so instead of crashing" do
    assert {:error, :not_switchable} = WebsiteAccess.set(:allowed_addresses, true, [])
  end

  test "set/3 reaches each feature's own switch" do
    {:ok, _} = WebsiteAccess.set(:redirect, true, [])
    assert Redirect.switched_on?()
    {:ok, _} = WebsiteAccess.set(:maintenance, true, [])
    assert Maintenance.active?()
    {:ok, _} = WebsiteAccess.set(:no_index, true, [])
    assert Crawlers.no_index_enabled?()
    assert feature(:no_index).on?, "shared with the Crawlers page"

    {:ok, _} = WebsiteAccess.set(:no_index, false, [])
    refute Crawlers.no_index_enabled?()
  end

  test "allowed addresses" do
    Settings.update_setting(AllowedAddresses.key(), "10.0.0.1\n 2001:db8::1 ,10.0.0.2")
    assert AllowedAddresses.list() == ["10.0.0.1", "2001:db8::1", "10.0.0.2"]
    assert AllowedAddresses.allowed?("10.0.0.2")
    refute AllowedAddresses.allowed?("10.0.0.20")
    refute AllowedAddresses.allowed?(nil)
    assert feature(:allowed_addresses).on?
  end

  test "the environment reads without exploding and never switches anything" do
    env = WebsiteAccess.environment()
    assert env.runtime in [:release, :mix]
    assert is_boolean(env.looks_like_dev?)
    assert is_list(env.reasons)
    refute Enum.any?(WebsiteAccess.features(), & &1.switched_on?)
  end

  defp feature(key), do: Enum.find(WebsiteAccess.features(), &(&1.key == key))

  # Every feature off — the state a live site is in.
  defp reset_features do
    {:ok, _} = Gate.set_enabled(false)
    {:ok, _} = WebsiteAccess.set(:redirect, false, [])
    {:ok, _} = Maintenance.set_active(false)
    {:ok, _} = Crawlers.update_no_index(false)
    :ok
  end
end
