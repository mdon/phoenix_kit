defmodule PhoenixKit.Dashboard.PerActionViewPermissionTest do
  @moduledoc """
  Issue #844: two admin tabs naming the SAME LiveView module but different
  `live_action`s (e.g. a landing redirector on one action, the real page on
  another) must cache and resolve their permissions independently.

  Before the fix, `Registry.auto_register_custom_permission/1` discarded the
  action and cached a single `view_module → permission` entry in
  `Permissions.custom_view_permissions/0`, so whichever tab registered LAST
  (registration order follows tab `priority`) silently overwrote the other's
  permission. Flipping `priority` on one tab therefore changed which key BOTH
  actions enforced, and a user holding the correct key for one action could
  be denied on mount and redirected right back onto the very page that denied
  them — an infinite redirect loop.
  """
  use ExUnit.Case, async: false

  # `auto_register_custom_permission/1` also tries to auto-grant the
  # registered key to Admin, which needs a database this unit test does not
  # have; that failure is logged and swallowed by design (see
  # `shared_permission_key_test.exs`), and is not what these tests are about.
  @moduletag :capture_log

  alias PhoenixKit.Dashboard.Registry
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKitWeb.Users.Auth

  defmodule FakeTabbedView do
  end

  defmodule FakeNoActionView do
  end

  setup do
    Permissions.clear_custom_keys()
    on_exit(fn -> Permissions.clear_custom_keys() end)
    :ok
  end

  defp tab(id, attrs) do
    Map.merge(%{id: id, label: to_string(id), path: to_string(id)}, Map.new(attrs))
  end

  defp scope(permissions) do
    %Scope{
      authenticated?: true,
      cached_roles: ["Editor"],
      cached_permissions: MapSet.new(permissions)
    }
  end

  test "two tabs on the same module, different actions, cache independently" do
    Registry.auto_register_custom_permission(
      tab(:reports_index, live_view: {FakeTabbedView, :index}, permission: "reports_view")
    )

    Registry.auto_register_custom_permission(
      tab(:reports_edit, live_view: {FakeTabbedView, :edit}, permission: "reports_manage")
    )

    assert Permissions.custom_view_permissions()[{FakeTabbedView, :index}] == "reports_view"
    assert Permissions.custom_view_permissions()[{FakeTabbedView, :edit}] == "reports_manage"

    assert Auth.permission_key_for_admin_view(FakeTabbedView, :index) == "reports_view"
    assert Auth.permission_key_for_admin_view(FakeTabbedView, :edit) == "reports_manage"
  end

  test "registration order does not decide which action's permission survives" do
    # Reverse order from the test above — the pre-fix bug made the LAST
    # registration (which follows tab `priority`) win for the whole module.
    Registry.auto_register_custom_permission(
      tab(:reports_edit, live_view: {FakeTabbedView, :edit}, permission: "reports_manage")
    )

    Registry.auto_register_custom_permission(
      tab(:reports_index, live_view: {FakeTabbedView, :index}, permission: "reports_view")
    )

    assert Auth.permission_key_for_admin_view(FakeTabbedView, :index) == "reports_view"
    assert Auth.permission_key_for_admin_view(FakeTabbedView, :edit) == "reports_manage"
  end

  test "a bare-atom live_view (no action) still resolves through the module-only fallback" do
    Registry.auto_register_custom_permission(
      tab(:legacy, live_view: FakeNoActionView, permission: "legacy_perm")
    )

    assert Permissions.custom_view_permissions()[FakeNoActionView] == "legacy_perm"
    assert Auth.permission_key_for_admin_view(FakeNoActionView) == "legacy_perm"
    assert Auth.permission_key_for_admin_view(FakeNoActionView, :whatever) == "legacy_perm"
  end

  test "can_access_admin_view?/3 distinguishes two actions of the same module" do
    Registry.auto_register_custom_permission(
      tab(:reports_index, live_view: {FakeTabbedView, :index}, permission: "reports_view")
    )

    Registry.auto_register_custom_permission(
      tab(:reports_edit, live_view: {FakeTabbedView, :edit}, permission: "reports_manage")
    )

    viewer = scope(["reports_view"])
    manager = scope(["reports_manage"])

    assert Auth.can_access_admin_view?(viewer, FakeTabbedView, :index)
    refute Auth.can_access_admin_view?(viewer, FakeTabbedView, :edit)

    refute Auth.can_access_admin_view?(manager, FakeTabbedView, :index)
    assert Auth.can_access_admin_view?(manager, FakeTabbedView, :edit)
  end

  test "can_access_admin_view?/2 without an action falls back to the module-only mapping" do
    Registry.auto_register_custom_permission(
      tab(:legacy, live_view: FakeNoActionView, permission: "legacy_perm")
    )

    assert Auth.can_access_admin_view?(scope(["legacy_perm"]), FakeNoActionView)
    refute Auth.can_access_admin_view?(scope(["other"]), FakeNoActionView)
  end

  test "a tab spelled `{Mod, nil}` is keyed like a bare module, so an :index lookup still resolves" do
    Registry.auto_register_custom_permission(
      tab(:nil_action, live_view: {FakeNoActionView, nil}, permission: "legacy_perm")
    )

    assert Auth.can_access_admin_view?(scope(["legacy_perm"]), FakeNoActionView, :index)
    assert Auth.can_access_admin_view?(scope(["legacy_perm"]), FakeNoActionView)
  end

  # The login return_to reachability check (`Session.reachable_return_to?/3`)
  # resolves the view AND the action from the router and asks the 3-arity
  # question. This pins that a route registered as `{Mod, :action}` — the
  # shape every real admin tab has — is answered by the action-aware lookup
  # and would be misjudged by the module-only one.
  test "a routed {Mod, :action} tab is reachable through the action-aware lookup only" do
    Registry.auto_register_custom_permission(
      tab(:reports_index, live_view: {FakeTabbedView, :index}, permission: "reports_view")
    )

    viewer = scope(["reports_view"])

    route = %{phoenix_live_view: {FakeTabbedView, :index, [], %{}}}
    {view, action, _opts, _meta} = route.phoenix_live_view

    assert Auth.can_access_admin_view?(viewer, view, action)
    refute Auth.can_access_admin_view?(viewer, view)
  end
end
