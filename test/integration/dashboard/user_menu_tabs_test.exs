defmodule PhoenixKit.Integration.Dashboard.UserMenuTabsTest do
  @moduledoc """
  Module user tabs flagged `user_menu:` reach both avatar dropdowns, and the
  core default user-dashboard tabs exist only while that dashboard is routed.

  With `user_dashboard_enabled: false` (the default) `/dashboard` and
  `/dashboard/settings` are not compiled into the host router, yet a module's
  own user tab (billing's "My Orders") still renders the dashboard sidebar —
  which used to carry "Dashboard" and "Settings" links straight into a
  NoRouteError (BeamLabEU/phoenix_kit#914). The account pages a signed-in
  visitor needs from every page now live in the avatar dropdown instead.

  The registry is not part of the test supervision tree, so the suite starts
  its own (sync, shared sandbox: init reads settings from the database).
  """
  use PhoenixKit.DataCase, async: false

  @moduletag :capture_log

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKit.Dashboard.{Registry, Tab}
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.{AdminNav, UserDashboardNav}

  setup do
    previous = Application.get_env(:phoenix_kit, :user_dashboard_enabled)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:phoenix_kit, :user_dashboard_enabled),
        else: Application.put_env(:phoenix_kit, :user_dashboard_enabled, previous)
    end)

    :ok
  end

  defp start_registry! do
    refute Process.whereis(Registry), "a registry is already running — this suite starts its own"
    start_supervised!(Registry)
    # A call is served only after handle_continue(:initialize_tabs) has run.
    :sys.get_state(Registry)
    :ok
  end

  defp scope! do
    {:ok, user} =
      Auth.register_user(%{
        email: "user-menu-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    Scope.for_user(user)
  end

  defp register_menu_tabs! do
    :ok =
      Registry.register(:user_menu_test, [
        Tab.new!(
          id: :um_orders,
          label: "Test Orders",
          icon: "hero-shopping-bag",
          path: "/dashboard/test-orders",
          priority: 200,
          user_menu: true
        ),
        Tab.new!(
          id: :um_gated_off,
          label: "Gated Off",
          path: "/dashboard/gated-off",
          priority: 210,
          user_menu: fn _scope -> false end
        ),
        Tab.new!(id: :um_sidebar_only, label: "Sidebar Only", path: "/test-shop", priority: 220),
        Tab.new!(
          id: :um_cart,
          label: "Test Cart",
          path: "/test-cart",
          priority: 230,
          user_menu: fn scope -> Scope.authenticated?(scope) end
        )
      ])
  end

  describe "default user-dashboard tabs (#914)" do
    test "are not registered while the user dashboard is disabled" do
      Application.put_env(:phoenix_kit, :user_dashboard_enabled, false)
      start_registry!()

      refute Registry.get_tab(:dashboard_home)
      refute Registry.get_tab(:dashboard_settings)
    end

    test "are registered while the user dashboard is enabled" do
      Application.put_env(:phoenix_kit, :user_dashboard_enabled, true)
      start_registry!()

      assert %Tab{path: "/dashboard"} = Registry.get_tab(:dashboard_home)
      assert %Tab{path: "/dashboard/settings"} = Registry.get_tab(:dashboard_settings)
    end
  end

  describe "get_user_menu_tabs/1" do
    test "returns the flagged tabs whose gate admits the scope, by priority" do
      start_registry!()
      register_menu_tabs!()

      assert Enum.map(Registry.get_user_menu_tabs(scope!()), & &1.id) == [:um_orders, :um_cart]
    end

    test "offers top-level tabs only, never a subtab of a flagged tab" do
      start_registry!()

      :ok =
        Registry.register(:user_menu_sub_test, [
          Tab.new!(id: :um_parent, label: "Parent", path: "/test-parent", user_menu: true),
          Tab.new!(
            id: :um_child,
            label: "Child",
            path: "/test-parent/child",
            parent: :um_parent,
            user_menu: true
          )
        ])

      assert Enum.map(Registry.get_user_menu_tabs(scope!()), & &1.id) == [:um_parent]
    end

    test "leaves out external tabs, whose links are not in-app paths" do
      start_registry!()

      :ok =
        Registry.register(:user_menu_ext_test, [
          Tab.new!(id: :um_in_app, label: "In App", path: "/test-in-app", user_menu: true),
          Tab.new!(
            id: :um_external,
            label: "External",
            path: "https://example.com/account",
            external: true,
            user_menu: true
          )
        ])

      assert Enum.map(Registry.get_user_menu_tabs(scope!()), & &1.id) == [:um_in_app]
    end

    test "leaves out a tab whose path is not absolute, which would raise in every dropdown" do
      start_registry!()

      :ok =
        Registry.register(:user_menu_rel_test, [
          Tab.new!(id: :um_absolute, label: "Absolute", path: "/test-absolute", user_menu: true),
          Tab.new!(id: :um_relative, label: "Relative", path: "test-relative", user_menu: true)
        ])

      assert Enum.map(Registry.get_user_menu_tabs(scope!()), & &1.id) == [:um_absolute]
    end

    test "answers empty for a missing scope instead of skipping the permission filter" do
      start_registry!()
      register_menu_tabs!()

      assert Registry.get_user_menu_tabs(nil) == []
    end

    test "answers empty without a running registry" do
      refute Process.whereis(Registry)
      assert Registry.get_user_menu_tabs(nil) == []
    end
  end

  describe "the avatar dropdowns" do
    setup do
      start_registry!()
      register_menu_tabs!()
      %{scope: scope!()}
    end

    test "the user dropdown lists flagged tabs after Settings, highlighting the current one",
         %{scope: scope} do
      assigns = %{scope: scope}

      html =
        rendered_to_string(~H"""
        <UserDashboardNav.user_dropdown
          scope={@scope}
          current_path="/en/test-cart/checkout"
          current_locale="en-US"
        />
        """)

      assert html =~ "Test Orders"
      assert html =~ "Test Cart"
      refute html =~ "Gated Off"
      refute html =~ "Sidebar Only"

      [_, after_settings] = String.split(html, "Settings", parts: 2)
      assert after_settings =~ "Test Orders"

      [cart_link] = Regex.run(~r/<a[^>]*test-cart[^>]*>/, html)
      assert cart_link =~ "bg-primary"
      [orders_link] = Regex.run(~r/<a[^>]*test-orders[^>]*>/, html)
      refute orders_link =~ "bg-primary"
    end

    test "a host can leave them out of the user dropdown", %{scope: scope} do
      assigns = %{scope: scope}

      html =
        rendered_to_string(~H"""
        <UserDashboardNav.user_dropdown
          scope={@scope}
          authenticated_links={[:settings, :logout]}
        />
        """)

      refute html =~ "Test Orders"
    end

    test "the admin top-bar dropdown lists them after Settings, highlighting the current one",
         %{scope: scope} do
      assigns = %{scope: scope}

      html =
        rendered_to_string(~H"""
        <AdminNav.admin_user_dropdown
          scope={@scope}
          current_path="/en/test-cart/checkout"
          current_locale="en-US"
        />
        """)

      assert html =~ "Test Orders"
      assert html =~ "Test Cart"
      refute html =~ "Gated Off"
      refute html =~ "Sidebar Only"

      [_, after_settings] = String.split(html, "Settings", parts: 2)
      assert after_settings =~ "Test Orders"

      [cart_link] = Regex.run(~r/<a[^>]*test-cart[^>]*>/, html)
      assert cart_link =~ "bg-primary"
      [orders_link] = Regex.run(~r/<a[^>]*test-orders[^>]*>/, html)
      refute orders_link =~ "bg-primary"
    end

    test "both dropdowns link through the prefix-aware path, not the raw tab path",
         %{scope: scope} do
      assigns = %{scope: scope}

      user_html =
        rendered_to_string(~H"""
        <UserDashboardNav.user_dropdown scope={@scope} current_path="/" current_locale="en-US" />
        """)

      admin_html =
        rendered_to_string(~H"""
        <AdminNav.admin_user_dropdown scope={@scope} current_path="/" current_locale="en-US" />
        """)

      for html <- [user_html, admin_html] do
        assert href(html, "test-orders") == Routes.path("/dashboard/test-orders", locale: "en")
        assert href(html, "test-cart") == Routes.path("/test-cart", locale: "en")
        refute href(html, "test-cart") == "/test-cart"
      end
    end

    test "both dropdowns carry the visitor's locale into the links", %{scope: scope} do
      {:ok, _} = Languages.enable_system()
      {:ok, _} = Languages.add_language("de-DE")
      assigns = %{scope: scope}

      user_html =
        rendered_to_string(~H"""
        <UserDashboardNav.user_dropdown scope={@scope} current_path="/" current_locale="de-DE" />
        """)

      admin_html =
        rendered_to_string(~H"""
        <AdminNav.admin_user_dropdown scope={@scope} current_path="/" current_locale="de-DE" />
        """)

      for html <- [user_html, admin_html] do
        assert href(html, "test-cart") == Routes.path("/test-cart", locale: "de")
        assert href(html, "test-cart") =~ "/de/"
      end
    end
  end

  defp href(html, fragment) do
    [_, href] = Regex.run(~r/<a[^>]*href="([^"]*#{fragment}[^"]*)"/, html)
    href
  end
end
