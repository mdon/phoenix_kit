defmodule PhoenixKit.WebsiteAccessTest do
  @moduledoc "The facade: the feature list, its switches, the presets."
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Settings
  alias PhoenixKit.WebsiteAccess
  alias PhoenixKit.WebsiteAccess.{AllowedAddresses, Gate, Notice, Redirect}

  setup do
    :ok = WebsiteAccess.apply_preset("live", [])
    Settings.update_setting(Gate.password_key(), "")
    Settings.update_setting(Redirect.url_key(), "")
    Settings.update_setting(Notice.text_key(), "")
    Settings.update_setting(Notice.link_key(), "")
    Settings.update_setting(AllowedAddresses.key(), "")
    Maintenance.clear_schedule()
    :ok
  end

  test "the feature list, in page order, all off on a live site" do
    keys = Enum.map(WebsiteAccess.features(), & &1.key)
    assert keys == [:gate, :redirect, :notice, :maintenance, :no_index, :allowed_addresses]
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

    :ok = Maintenance.update_schedule(DateTime.add(DateTime.utc_now(), -60, :second), nil)
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
    {:ok, _} = WebsiteAccess.set(:notice, true, [])
    assert Notice.switched_on?()
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

  describe "presets" do
    test "maintenance: the closed page with maintenance texts, nothing else touched" do
      Crawlers.update_no_index(false)
      assert :ok = WebsiteAccess.apply_preset("maintenance", [])
      assert Maintenance.active?()
      assert Maintenance.get_header() == "Maintenance"
      assert Maintenance.get_subtext() =~ "doing some work"
      refute Crawlers.no_index_enabled?(), "a live site stays indexed"
      refute Notice.switched_on?()
      refute Gate.switched_on?()
    end

    test "applying Maintenance after Under construction changes the stock texts" do
      :ok = WebsiteAccess.apply_preset("under_construction", [])
      assert Maintenance.get_header() == "Under construction"
      :ok = WebsiteAccess.apply_preset("maintenance", [])
      assert Maintenance.get_header() == "Maintenance"
    end

    test "under construction: closed page + construction notice + noindex" do
      assert :ok = WebsiteAccess.apply_preset("under_construction", [])
      assert Maintenance.active?()
      assert Maintenance.get_header() == "Under construction", "the stock heading is replaced"
      assert Maintenance.get_subtext() != Maintenance.default_subtext()
      assert Notice.switched_on?()
      assert Notice.icon() == "construction"
      assert Notice.text() != ""
      assert Crawlers.no_index_enabled?()
      refute Gate.switched_on?()
    end

    test "under construction keeps a message the admin already wrote" do
      {:ok, _} = Maintenance.update_header("Closed for the season")
      {:ok, _} = Settings.update_setting(Notice.text_key(), "Mind the dust")
      :ok = WebsiteAccess.apply_preset("under_construction", [])
      assert Maintenance.get_header() == "Closed for the season"
      assert Notice.text() == "Mind the dust"
    end

    test "dev site: gate + noindex + warning notice pointing at production" do
      Settings.update_setting(Redirect.url_key(), "https://www.example.com")
      assert :ok = WebsiteAccess.apply_preset("dev_site", [])
      assert Gate.switched_on?()
      assert Crawlers.no_index_enabled?()
      assert Notice.icon() == "warning"
      assert Notice.link() == "https://www.example.com"
      refute Maintenance.active?()
      refute Redirect.switched_on?(), "a preset never starts redirecting on its own"
    end

    test "live: everything off" do
      :ok = WebsiteAccess.apply_preset("dev_site", [])
      :ok = WebsiteAccess.apply_preset("under_construction", [])
      assert :ok = WebsiteAccess.apply_preset("live", [])
      refute Enum.any?(WebsiteAccess.features(), & &1.switched_on?)
      refute Crawlers.no_index_enabled?()
    end

    test "unknown preset" do
      assert {:error, :unknown_preset} = WebsiteAccess.apply_preset("nope", [])
    end

    test "every preset is listed with a label" do
      keys = Enum.map(WebsiteAccess.presets(), & &1.key)
      assert keys == ["maintenance", "under_construction", "dev_site", "live"]
    end
  end

  test "the environment reads without exploding and never switches anything" do
    env = WebsiteAccess.environment()
    assert env.runtime in [:release, :mix]
    assert is_boolean(env.looks_like_dev?)
    assert is_list(env.reasons)
    refute Enum.any?(WebsiteAccess.features(), & &1.switched_on?)
  end

  defp feature(key), do: Enum.find(WebsiteAccess.features(), &(&1.key == key))
end
