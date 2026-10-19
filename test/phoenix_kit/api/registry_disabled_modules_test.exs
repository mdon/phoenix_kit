defmodule PhoenixKit.API.RegistryDisabledModulesTest do
  @moduledoc """
  `api_disabled_modules`: a module key listed there has all its tools withheld by
  `PhoenixKit.API.Registry`, like tools hidden by `api_disabled_tools`. Every module is on
  until listed, and core's own tools belong to no module.
  """
  # async: false - modules are registered globally and settings are shared.
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.Registry
  alias PhoenixKit.API.Tool
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings

  defmodule AlphaFake do
    def module_key, do: "regmod_alpha"
    def module_name, do: "Alpha"
    def enabled?, do: :persistent_term.get({__MODULE__, :enabled}, true)

    def api_tools do
      [
        Tool.new!(
          name: "regmod_alpha.list_things",
          audience: :admin,
          scope: "regmod_alpha.things:read",
          permission: "regmod",
          handler: {__MODULE__, :run}
        ),
        Tool.new!(name: "regmod_alpha.search", audience: :public, handler: {__MODULE__, :run})
      ]
    end

    def run(_input, _ctx), do: {:ok, %{}}
  end

  defmodule BetaFake do
    def module_key, do: "regmod_beta"
    def module_name, do: "Beta"
    def enabled?, do: true

    def api_tools do
      [
        Tool.new!(
          name: "regmod_beta.list_things",
          audience: :admin,
          scope: "regmod_beta.things:read",
          permission: "regmod",
          handler: {__MODULE__, :run}
        )
      ]
    end

    def run(_input, _ctx), do: {:ok, %{}}
  end

  # Declares no tools: it must not be listed as an API module.
  defmodule QuietFake do
    def module_key, do: "regmod_quiet"
    def module_name, do: "Quiet"
    def enabled?, do: true
  end

  setup do
    :persistent_term.put({AlphaFake, :enabled}, true)
    for mod <- [AlphaFake, BetaFake, QuietFake], do: ModuleRegistry.register(mod)

    on_exit(fn ->
      for mod <- [AlphaFake, BetaFake, QuietFake], do: ModuleRegistry.unregister(mod)
      :persistent_term.erase({AlphaFake, :enabled})
    end)

    :ok
  end

  defp names, do: Registry.all_tools() |> Enum.map(& &1.name) |> Enum.sort()

  defp switch_off(keys) do
    {:ok, _} = Settings.update_setting("api_disabled_modules", Config.encode_list(keys))
  end

  test "every module is on by default" do
    assert Config.disabled_modules() == []
    assert {:ok, []} = Config.fetch_disabled_modules()
    assert "regmod_alpha.list_things" in names()
    assert "regmod_beta.list_things" in names()
  end

  test "a listed module loses all its tools, in every audience, and the others keep theirs" do
    switch_off(["regmod_alpha"])

    refute "regmod_alpha.list_things" in names()
    refute "regmod_alpha.search" in names()
    assert "regmod_beta.list_things" in names()

    assert {:error, :not_found} = Registry.find("regmod_alpha.list_things", :admin)
    assert {:error, :not_found} = Registry.find("regmod_alpha.search", :public)
    assert {:ok, %Tool{}} = Registry.find("regmod_beta.list_things", :admin)

    assert Registry.visible_tools(:admin, :all)
           |> Enum.map(& &1.name)
           |> Enum.member?("regmod_alpha.list_things") ==
             false

    assert Registry.visible_tools(:public, :all)
           |> Enum.map(& &1.name)
           |> Enum.member?("regmod_alpha.search") ==
             false
  end

  test "switching it back restores the tools" do
    switch_off(["regmod_alpha"])
    refute "regmod_alpha.list_things" in names()

    switch_off([])
    assert "regmod_alpha.list_things" in names()
    assert {:ok, %Tool{module: AlphaFake}} = Registry.find("regmod_alpha.list_things", :admin)
  end

  test "core's own tools belong to no module and stay" do
    switch_off(["regmod_alpha", "regmod_beta", "system", "core", "api"])

    assert {:ok, %Tool{}} = Registry.find("system.get_identity", :admin)
    assert "system.get_identity" in names()
  end

  test "a module that is also disabled answers not_found, a disabled one that is not listed module_disabled" do
    :persistent_term.put({AlphaFake, :enabled}, false)
    assert {:error, :module_disabled} = Registry.find("regmod_alpha.list_things", :admin)

    switch_off(["regmod_alpha"])
    assert {:error, :not_found} = Registry.find("regmod_alpha.list_things", :admin)
  end

  test "a key of a module that is not installed is kept in the list and harms nothing" do
    switch_off(["gone_module", "regmod_alpha"])

    assert Config.disabled_modules() == ["gone_module", "regmod_alpha"]
    assert "regmod_beta.list_things" in names()
  end

  describe "ModuleRegistry.api_modules/0" do
    test "lists the modules that declare tools, with their key, name and tool count" do
      modules = ModuleRegistry.api_modules()
      keys = Enum.map(modules, & &1.key)

      assert "regmod_alpha" in keys
      assert "regmod_beta" in keys
      refute "regmod_quiet" in keys

      assert %{module: AlphaFake, name: "Alpha", enabled?: true, tools: 2} =
               Enum.find(modules, &(&1.key == "regmod_alpha"))
    end

    test "lists a switched-off module too, marked as such" do
      :persistent_term.put({AlphaFake, :enabled}, false)

      assert %{enabled?: false} =
               Enum.find(ModuleRegistry.api_modules(), &(&1.key == "regmod_alpha"))
    end

    test "is not narrowed by api_disabled_modules" do
      switch_off(["regmod_alpha"])

      assert "regmod_alpha" in Enum.map(ModuleRegistry.api_modules(), & &1.key)
    end
  end
end
