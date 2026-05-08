defmodule PhoenixKitWeb.Users.AuthTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitWeb.Users.Auth

  # `permission_key_for_admin_view/1` is exposed as `@doc false def` so this
  # test can exercise the static map, the custom-tabs lookup, the
  # `PhoenixKit.Modules.*` namespace branch, and the registered-plugin
  # branch added for external modules (PhoenixKitEntities, PhoenixKitBilling, …).

  # Fixture module created with an explicit top-level name. `defmodule X` inside
  # a test gets auto-nested under the test module's namespace, which would make
  # `Module.split/1` return the wrong head segment — Module.create/3 dodges that.
  setup_all do
    Module.create(
      PhoenixKitFakePluginFixture,
      quote do
        def module_key, do: "fake_plugin"
      end,
      Macro.Env.location(__ENV__)
    )

    :ok
  end

  describe "permission_key_for_admin_view/1" do
    test "returns key from static @admin_view_permissions map" do
      assert Auth.permission_key_for_admin_view(PhoenixKitWeb.Live.Dashboard) ==
               "dashboard"

      assert Auth.permission_key_for_admin_view(PhoenixKitWeb.Live.Users.Users) ==
               "users"
    end

    test "infers key from PhoenixKit.Modules.<Name>.Web.* namespace" do
      assert Auth.permission_key_for_admin_view(PhoenixKit.Modules.Tickets.Web.Index) ==
               "tickets"

      assert Auth.permission_key_for_admin_view(PhoenixKit.Modules.NewsLetters.Web.Show) ==
               "news_letters"
    end

    test "resolves external plugin namespace via ModuleRegistry" do
      ModuleRegistry.register(PhoenixKitFakePluginFixture)
      on_exit(fn -> ModuleRegistry.unregister(PhoenixKitFakePluginFixture) end)

      assert Auth.permission_key_for_admin_view(PhoenixKitFakePluginFixture.Web.Index) ==
               "fake_plugin"

      assert Auth.permission_key_for_admin_view(PhoenixKitFakePluginFixture.Web.Edit.Form) ==
               "fake_plugin"
    end

    test "returns nil for unknown views (preserves fail-closed default)" do
      assert Auth.permission_key_for_admin_view(SomeRandomUnregisteredModule) == nil
    end
  end
end
