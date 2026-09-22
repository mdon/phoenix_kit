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
  # question. This pins that a route registered as `{Mod, :action}` is
  # answered by the action-aware lookup. The difference is only observable
  # when the module's tabs DISAGREE: a module whose tabs share one permission
  # answers the module-only question too (see the untabbed-action tests
  # below), so this uses the #844 shape.
  test "a routed {Mod, :action} tab is reachable through the action-aware lookup only" do
    Registry.auto_register_custom_permission(
      tab(:reports_index, live_view: {FakeTabbedView, :index}, permission: "reports_view")
    )

    Registry.auto_register_custom_permission(
      tab(:reports_edit, live_view: {FakeTabbedView, :edit}, permission: "reports_manage")
    )

    viewer = scope(["reports_view"])

    route = %{phoenix_live_view: {FakeTabbedView, :index, [], %{}}}
    {view, action, _opts, _meta} = route.phoenix_live_view

    assert Auth.can_access_admin_view?(viewer, view, action)
    refute Auth.can_access_admin_view?(viewer, view)
  end

  describe "an action with no tab of its own (review of #850)" do
    # One LiveView serving several actions while only one is a tab is the
    # common admin shape: a tab on `:index`, and `:show` / `:edit` routed to
    # the same module. Before per-action keys the tab was cached under the
    # bare module, so those actions were guarded by its permission; they must
    # still be, or a partial role holding the tab's key can open the list and
    # none of the records in it.

    test "is guarded by the module's tab permission when that is the only one" do
      Registry.auto_register_custom_permission(
        tab(:reports_index, live_view: {FakeTabbedView, :index}, permission: "reports_view")
      )

      for action <- [:show, :edit, nil] do
        assert Auth.permission_key_for_admin_view(FakeTabbedView, action) == "reports_view",
               "action: #{inspect(action)}"
      end

      viewer = scope(["reports_view"])
      assert Auth.can_access_admin_view?(viewer, FakeTabbedView, :show)
      assert Auth.can_access_admin_view?(viewer, FakeTabbedView, :edit)

      refute Auth.can_access_admin_view?(scope(["something_else"]), FakeTabbedView, :show)
    end

    test "is guarded when several tabs name the module with the same permission" do
      for {id, action} <- [reports_index: :index, reports_archive: :archive] do
        Registry.auto_register_custom_permission(
          tab(id, live_view: {FakeTabbedView, action}, permission: "reports_view")
        )
      end

      assert Auth.permission_key_for_admin_view(FakeTabbedView, :show) == "reports_view"
    end

    test "stays unmapped — fails closed — when the module's tabs disagree (#844)" do
      Registry.auto_register_custom_permission(
        tab(:reports_index, live_view: {FakeTabbedView, :index}, permission: "reports_view")
      )

      Registry.auto_register_custom_permission(
        tab(:reports_edit, live_view: {FakeTabbedView, :edit}, permission: "reports_manage")
      )

      # The tabbed actions still resolve exactly.
      assert Auth.permission_key_for_admin_view(FakeTabbedView, :index) == "reports_view"
      assert Auth.permission_key_for_admin_view(FakeTabbedView, :edit) == "reports_manage"

      # An action neither tab names has no safe answer.
      assert Auth.permission_key_for_admin_view(FakeTabbedView, :show) == nil
      refute Auth.can_access_admin_view?(scope(["reports_view"]), FakeTabbedView, :show)
      refute Auth.can_access_admin_view?(scope(["reports_manage"]), FakeTabbedView, :show)
    end

    test "a bare-module entry does not authorize an untabbed action when the tabs disagree" do
      Registry.auto_register_custom_permission(
        tab(:reports_index, live_view: {FakeTabbedView, :index}, permission: "reports_view")
      )

      Registry.auto_register_custom_permission(
        tab(:reports_edit, live_view: {FakeTabbedView, :edit}, permission: "reports_manage")
      )

      Permissions.cache_custom_view_permission(FakeTabbedView, "reports_view")

      assert Auth.permission_key_for_admin_view(FakeTabbedView, :show) == nil
    end

    test "a namespaced module does not fall through to its inferred key" do
      # `PhoenixKit.Modules.<Name>.Web.*` infers `"<name>"` when nothing is
      # cached. A disagreeing pair must stay unmapped instead — the fixture
      # modules above never reach that branch, so they cannot catch it.
      view = namespaced_view!()

      Registry.auto_register_custom_permission(
        tab(:idx, live_view: {view, :index}, permission: "reports_view")
      )

      Registry.auto_register_custom_permission(
        tab(:ed, live_view: {view, :edit}, permission: "reports_manage")
      )

      assert Auth.permission_key_for_admin_view(view, :index) == "reports_view"
      assert Auth.permission_key_for_admin_view(view, :show) == nil
      refute Auth.can_access_admin_view?(scope(["reports_fixture"]), view, :show)
    end
  end

  defp namespaced_view! do
    mod = PhoenixKit.Modules.ReportsFixture.Web.Index

    unless Code.ensure_loaded?(mod) do
      {:module, ^mod, _, _} =
        Module.create(
          mod,
          quote do
            def __fixture__, do: :ok
          end,
          Macro.Env.location(__ENV__)
        )
    end

    mod
  end
end
