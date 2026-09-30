defmodule PhoenixKitWeb.Live.Modules.RequiredModulesBadgeTest do
  @moduledoc """
  The "Requires …" badge on an external module's card on the Modules page
  shows only for a required module that is off. Storage reports its state as
  `module_enabled` (it is always on), and the badge used to read `enabled`,
  so every external module requiring Storage showed "Requires Storage".
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKit.Utils.Routes

  defmodule NeedsStorage do
    @moduledoc false
    def module_key, do: "badge_test_needs_storage"
    def module_name, do: "Badge Test Needs Storage"
    def enabled?, do: false
    def get_config, do: %{enabled: false}
    def required_modules, do: ["storage"]

    def permission_metadata,
      do: %{key: module_key(), label: module_name(), icon: "hero-photo", description: "Stub"}
  end

  defmodule NeedsOffModule do
    @moduledoc false
    def module_key, do: "badge_test_needs_off"
    def module_name, do: "Badge Test Needs Off"
    def enabled?, do: false
    def get_config, do: %{enabled: false}
    def required_modules, do: ["badge_test_off_module"]

    def permission_metadata,
      do: %{key: module_key(), label: module_name(), icon: "hero-photo", description: "Stub"}
  end

  setup do
    previous = Application.get_env(:phoenix_kit, :modules)
    Application.put_env(:phoenix_kit, :modules, [NeedsStorage, NeedsOffModule])
    # Registered, so their keys are module keys; granted to Admin, so the
    # page lists their cards.
    Enum.each([NeedsStorage, NeedsOffModule], &ModuleRegistry.register/1)
    admin = Roles.get_role_by_name("Admin")

    for mod <- [NeedsStorage, NeedsOffModule],
        do: {:ok, _} = Permissions.grant_permission(admin.uuid, mod.module_key())

    on_exit(fn ->
      Enum.each([NeedsStorage, NeedsOffModule], &ModuleRegistry.unregister/1)

      if previous,
        do: Application.put_env(:phoenix_kit, :modules, previous),
        else: Application.delete_env(:phoenix_kit, :modules)
    end)

    :ok
  end

  test "Storage, always on, is never shown as a missing requirement", %{conn: conn} do
    {user, _token} = create_admin_user()
    {:ok, view, _html} = live(log_in_user(conn, user), Routes.path("/admin/modules"))

    html = render_click(view, "switch_modules_tab", %{"tab" => "disabled"})

    # Both stub cards are on the Disabled tab.
    assert html =~ "Badge Test Needs Storage"
    assert html =~ "Badge Test Needs Off"

    refute html =~ "Requires Storage"
    # The control: a requirement that is really off still shows.
    assert html =~ "Requires Badge_test_off_module"
  end
end
