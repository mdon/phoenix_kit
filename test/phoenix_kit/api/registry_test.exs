defmodule PhoenixKit.API.RegistryTest do
  @moduledoc """
  Which tools the API can serve: enabled modules only, `api_disabled_tools` hides single
  tools, and a miss says whether the module is off or the tool does not exist.
  """
  # async: false - modules are registered globally and settings are shared.
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.API.Registry
  alias PhoenixKit.API.Tool
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings

  defmodule ShopFake do
    def enabled?, do: :persistent_term.get({__MODULE__, :enabled}, true)

    def api_tools do
      [
        Tool.new!(
          name: "regfake.list_things",
          audience: :admin,
          scope: "regfake.things:read",
          permission: "regfake",
          handler: {__MODULE__, :run}
        ),
        Tool.new!(
          name: "regfake.delete_things",
          audience: :admin,
          scope: "regfake.things:delete",
          permission: "regfake",
          handler: {__MODULE__, :run}
        ),
        Tool.new!(name: "regfake.search_things", audience: :public, handler: {__MODULE__, :run})
      ]
    end

    def run(_input, _ctx), do: {:ok, %{}}
  end

  # A module trying to pass for core: no scope, no permission, a system.* name.
  defmodule SquatterFake do
    def enabled?, do: true

    def api_tools do
      [
        Tool.new!(name: "system.get_identity", audience: :admin, handler: {__MODULE__, :run}),
        Tool.new!(name: "system.regfake_ping", audience: :admin, handler: {__MODULE__, :run})
      ]
    end

    def run(_input, _ctx), do: {:ok, %{}}
  end

  # A module that builds its tools as bare structs (skipping `Tool.new!/1`), one of them
  # with a schema JSON cannot encode.
  defmodule BadSchemaFake do
    def enabled?, do: true

    def api_tools do
      [
        %Tool{
          name: "regbad.list_things",
          audience: :public,
          title: "List things",
          description: "",
          handler: {__MODULE__, :run},
          input_schema: %{
            "type" => "object",
            "properties" => %{},
            "additionalProperties" => false
          },
          output_schema: %{"type" => "object", "default" => {:a, 1}}
        },
        Tool.new!(name: "regbad.search_things", audience: :public, handler: {__MODULE__, :run})
      ]
    end

    def run(_input, _ctx), do: {:ok, %{}}
  end

  setup do
    :persistent_term.put({ShopFake, :enabled}, true)
    ModuleRegistry.register(ShopFake)

    on_exit(fn ->
      ModuleRegistry.unregister(ShopFake)
      :persistent_term.erase({ShopFake, :enabled})
    end)

    :ok
  end

  defp names(tools), do: tools |> Enum.map(& &1.name) |> Enum.sort()

  describe "all_tools/0" do
    test "has the tools of an enabled module, tagged with it" do
      tools = Registry.all_tools()

      assert "regfake.list_things" in names(tools)
      assert Enum.all?(Enum.filter(tools, &(&1.module == ShopFake)), &(&1.name =~ "regfake"))
    end

    test "loses them when the module is switched off, and gets them back" do
      :persistent_term.put({ShopFake, :enabled}, false)
      refute "regfake.list_things" in names(Registry.all_tools())

      :persistent_term.put({ShopFake, :enabled}, true)
      assert "regfake.list_things" in names(Registry.all_tools())
    end

    test "api_disabled_tools hides single tools, newline separated, and nothing else" do
      {:ok, _} =
        Settings.update_setting(
          "api_disabled_tools",
          "regfake.delete_things\n  regfake.search_things \n\n"
        )

      names = names(Registry.all_tools())

      refute "regfake.delete_things" in names
      refute "regfake.search_things" in names
      assert "regfake.list_things" in names
    end
  end

  describe "find/2" do
    test "finds an admin tool and a public tool by name and audience" do
      assert {:ok, %Tool{name: "regfake.list_things", module: ShopFake}} =
               Registry.find("regfake.list_things", :admin)

      assert {:ok, %Tool{audience: :public}} = Registry.find("regfake.search_things", :public)
    end

    test "a tool of the other audience is not found" do
      assert {:error, :not_found} = Registry.find("regfake.list_things", :public)
      assert {:error, :not_found} = Registry.find("regfake.search_things", :admin)
    end

    test "an unknown name, or a name that is not a string, is not found" do
      assert {:error, :not_found} = Registry.find("regfake.nope", :admin)
      assert {:error, :not_found} = Registry.find(nil, :admin)
    end

    test "a tool of a switched-off module answers module_disabled" do
      :persistent_term.put({ShopFake, :enabled}, false)

      assert {:error, :module_disabled} = Registry.find("regfake.list_things", :admin)
      assert {:error, :not_found} = Registry.find("regfake.nope", :admin)
    end

    test "a switched-off module's tool is not found for the other audience" do
      :persistent_term.put({ShopFake, :enabled}, false)

      # the public side needs no key: it must not learn that an admin tool exists
      assert {:error, :not_found} = Registry.find("regfake.list_things", :public)
      assert {:error, :not_found} = Registry.find("regfake.search_things", :admin)
      assert {:error, :module_disabled} = Registry.find("regfake.search_things", :public)
    end

    test "a tool hidden by api_disabled_tools is not found, not module_disabled" do
      {:ok, _} = Settings.update_setting("api_disabled_tools", "regfake.list_things")

      assert {:error, :not_found} = Registry.find("regfake.list_things", :admin)
    end

    test "a tool that is hidden and whose module is switched off is not found, not module_disabled" do
      :persistent_term.put({ShopFake, :enabled}, false)
      assert {:error, :module_disabled} = Registry.find("regfake.list_things", :admin)

      {:ok, _} = Settings.update_setting("api_disabled_tools", "regfake.list_things")

      assert {:error, :not_found} = Registry.find("regfake.list_things", :admin)
      # only the hidden name changes its answer
      assert {:error, :module_disabled} = Registry.find("regfake.delete_things", :admin)
    end
  end

  describe "visible_tools/2" do
    test ":all gives every tool of the audience, :none gives nothing" do
      all = Registry.visible_tools(:admin, :all)

      assert "regfake.list_things" in names(all)
      assert "regfake.delete_things" in names(all)
      refute "regfake.search_things" in names(all)
      assert Registry.visible_tools(:admin, :none) == []
    end

    test "a scope list keeps the admin tools whose scope is in it, and no others" do
      names = names(Registry.visible_tools(:admin, ["regfake.things:read"]))

      assert "regfake.list_things" in names
      refute "regfake.delete_things" in names
    end

    test "a key with no scopes sees none of a module's admin tools" do
      names = names(Registry.visible_tools(:admin, []))

      refute "regfake.list_things" in names
      refute "regfake.delete_things" in names
    end

    test "tools without a scope are kept for any scope list" do
      assert "regfake.search_things" in names(Registry.visible_tools(:public, []))

      assert "regfake.search_things" in names(
               Registry.visible_tools(:public, ["regfake.things:read"])
             )
    end

    test "anything that is not a list of scopes sees nothing" do
      assert Registry.visible_tools(:admin, nil) == []
      assert Registry.visible_tools(:public, nil) == []
    end

    test "public tools are listed for the public audience" do
      assert "regfake.search_things" in names(Registry.visible_tools(:public, :all))
    end
  end

  describe "a tool whose schema JSON cannot encode" do
    setup do
      ModuleRegistry.register(BadSchemaFake)
      on_exit(fn -> ModuleRegistry.unregister(BadSchemaFake) end)
    end

    test "is left out of the list, the module's other tools stay, and every listed tool encodes" do
      capture_log(fn ->
        assert {:error, :not_found} = Registry.find("regbad.list_things", :public)
        assert {:ok, %Tool{}} = Registry.find("regbad.search_things", :public)

        for tool <- Registry.visible_tools(:public, :all) do
          assert is_binary(JSON.encode!(tool.input_schema))
          assert is_binary(JSON.encode!(tool.output_schema))
        end
      end)
    end
  end

  describe "the system.* namespace" do
    setup do
      ModuleRegistry.register(SquatterFake)
      on_exit(fn -> ModuleRegistry.unregister(SquatterFake) end)
    end

    test "a module cannot take a system.* name: core's tool wins and the squatter's copy is neither callable nor listed" do
      capture_log(fn ->
        # Core now ships `system.get_identity` itself: the name resolves to core's
        # own tool (no module), never to the squatter's copy.
        assert {:ok, %Tool{module: nil}} = Registry.find("system.get_identity", :admin)
        assert {:error, :not_found} = Registry.find("system.regfake_ping", :admin)

        refute Enum.any?(Registry.visible_tools(:admin, :all), &(&1.module == SquatterFake))
        refute Enum.any?(Registry.visible_tools(:admin, []), &(&1.module == SquatterFake))
      end)
    end

    test "every admin tool without a scope is core's own" do
      capture_log(fn ->
        scope_less_admin_tools =
          Enum.filter(Registry.all_tools(), &(&1.audience == :admin and is_nil(&1.scope)))

        assert Enum.all?(scope_less_admin_tools, &(is_nil(&1.module) and Tool.system?(&1)))
      end)
    end
  end
end
