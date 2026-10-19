defmodule PhoenixKitWeb.Live.HeaderWidgetsTest do
  @moduledoc """
  A module's header widgets (`PhoenixKit.Module.header_widgets/0`) in the admin layout of a
  real, connected LiveView: rendered as sticky nested LiveViews before the notifications
  bell, only for enabled modules, and the optional dock column (`#pk-dock`) only while a
  rendered widget declares it.

  What the layout looks like with no widget at all is pinned by
  test/phoenix_kit_web/components/layout_wrapper_header_widgets_snapshot_test.exs.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]

  alias Phoenix.LiveView.JS
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKitWeb.Components.AdminDock
  alias PhoenixKitWeb.Test.HeaderWidgetProbeLive

  @path "/phoenix_kit/admin/__test/admin-edit-probe"

  defmodule PlainModule do
    def enabled?, do: true

    def header_widgets do
      [{HeaderWidgetProbeLive, "pk-test-widget", &__MODULE__.session/1}]
    end

    def session(assigns) do
      %{
        "label" => "plain",
        "user_uuid" => assigns.phoenix_kit_current_user.uuid,
        "locale" => assigns[:current_locale_base]
      }
    end
  end

  defmodule DockModule do
    def enabled?, do: true

    def header_widgets do
      [
        {HeaderWidgetProbeLive, "pk-test-dock-widget", &PlainModule.session/1, dock: true}
      ]
    end
  end

  # Its session function reads nothing from the assigns, so a widget that is rendered when it
  # should not be cannot be hidden by the registry dropping it for a raising session function.
  defmodule BareDockModule do
    def enabled?, do: true

    def header_widgets do
      [{HeaderWidgetProbeLive, "pk-test-bare-widget", &__MODULE__.session/1, dock: true}]
    end

    def session(_assigns), do: %{"label" => "bare"}
  end

  defmodule OffModule do
    def enabled?, do: false

    def header_widgets do
      [
        {HeaderWidgetProbeLive, "pk-test-off-widget", &PlainModule.session/1, dock: true}
      ]
    end
  end

  defp with_registered(modules, fun) do
    Enum.each(modules, &ModuleRegistry.register/1)

    try do
      fun.()
    after
      Enum.each(modules, &ModuleRegistry.unregister/1)
    end
  end

  defp admin_live(conn, path \\ @path) do
    {admin, _} = create_admin_user()
    {:ok, view, html} = live(log_in_user(conn, admin), path)
    {admin, view, html}
  end

  @owner_scope %PhoenixKit.Users.Auth.Scope{
    user: %PhoenixKit.Users.Auth.User{
      uuid: "0193a5e4-0000-7000-8000-0000000000d1",
      email: "head@example.com"
    },
    authenticated?: true,
    cached_roles: ["Owner"],
    cached_permissions: MapSet.new(PhoenixKit.Users.Permissions.all_module_keys())
  }

  # The admin layout rendered outside a connected LiveView, with the given socket and scope.
  defp render_layout(socket, scope) do
    assigns = %{socket: socket, scope: scope}

    rendered_to_string(~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={%{}}
      socket={@socket}
      current_path="/admin"
      page_title="Dashboard"
      project_title="Acme"
      phoenix_kit_current_scope={@scope}
    >
      body
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """)
  end

  defp class_tokens(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("class")
    |> List.first()
    |> String.split()
  end

  # Where a marker sits in the document: widgets must come before the bell.
  defp position(html, marker) do
    case :binary.match(html, marker) do
      {at, _} -> at
      :nomatch -> flunk("#{marker} is not in the page")
    end
  end

  setup do
    # The bell renders only with notifications on; the widget is placed relative to it.
    Settings.update_boolean_setting("notifications_enabled", true)
    :ok
  end

  describe "with no module that declares a widget" do
    test "the layout has the bell, no widget and no dock", %{conn: conn} do
      {_admin, view, html} = admin_live(conn)

      assert html =~ ~s(id="pk-notifications-bell")
      refute html =~ "pk-test-widget"
      refute has_element?(view, "#pk-dock")
      assert has_element?(view, "#admin-drawer")
    end
  end

  describe "a widget without a dock" do
    test "is rendered as a sticky nested LiveView before the bell", %{conn: conn} do
      with_registered([PlainModule], fn ->
        {admin, view, html} = admin_live(conn)

        assert has_element?(view, ~s(header #pk-test-widget[data-phx-sticky]))

        assert position(html, ~s(id="pk-test-widget")) <
                 position(html, ~s(id="pk-notifications-bell"))

        # The session function got the layout's assigns, user included.
        child = find_live_child(view, "pk-test-widget")
        assert render(child) =~ ~s(data-user="#{admin.uuid}")
        assert render(child) =~ "widget plain"
      end)
    end

    test "does not add the dock column", %{conn: conn} do
      with_registered([PlainModule], fn ->
        {_admin, view, html} = admin_live(conn)

        refute has_element?(view, "#pk-dock")
        refute html =~ "pk-dock"
      end)
    end
  end

  describe "a module that is switched off" do
    test "contributes neither the widget nor the dock", %{conn: conn} do
      with_registered([OffModule], fn ->
        {_admin, view, html} = admin_live(conn)

        refute html =~ "pk-test-off-widget"
        refute has_element?(view, "#pk-dock")
      end)
    end
  end

  describe "a widget that declares the dock" do
    test "adds #pk-dock to the drawer, closed", %{conn: conn} do
      with_registered([DockModule], fn ->
        {_admin, view, html} = admin_live(conn)

        assert has_element?(view, "header #pk-test-dock-widget[data-phx-sticky]")
        assert has_element?(view, "#admin-drawer > #{"#" <> AdminDock.container_id()}")

        # Closed: the layout does not set the open class, the widget's command does.
        refute has_element?(view, "#admin-drawer.#{AdminDock.open_class()}")
        assert "hidden" in class_tokens(view, "#pk-dock")
        assert html =~ ~s(id="pk-dock")
      end)
    end

    test "is shown by the open class on the drawer or on any element inside it", %{conn: conn} do
      with_registered([DockModule], fn ->
        {_admin, view, _html} = admin_live(conn)

        # The class on #admin-drawer is lost when a live redirect swaps the page; a class on
        # an element inside the sticky widget travels with the widget. Both open the dock.
        tokens = class_tokens(view, "#pk-dock")

        assert "[.#{AdminDock.open_class()}_&]:block" in tokens

        assert "[##{AdminDock.drawer_id()}:has(.#{AdminDock.open_class()})_&]:block" in tokens
      end)
    end

    test "a layout rendered with no socket and no user gets neither widget nor dock" do
      with_registered([DockModule], fn ->
        assigns = %{}

        html =
          rendered_to_string(~H"""
          <PhoenixKitWeb.Components.LayoutWrapper.app_layout
            flash={%{}}
            socket={nil}
            current_path="/admin"
            page_title="Dashboard"
            project_title="Acme"
            phoenix_kit_current_scope={
              %PhoenixKit.Users.Auth.Scope{
                user: nil,
                authenticated?: true,
                cached_roles: ["Owner"],
                cached_permissions: MapSet.new(PhoenixKit.Users.Permissions.all_module_keys())
              }
            }
          >
            body
          </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
          """)

        refute html =~ "pk-dock"
        refute html =~ "pk-test-dock-widget"
      end)
    end
  end

  describe "the layout's guards" do
    test "a signed-in user but no socket: no widget, no dock, no crash" do
      with_registered([BareDockModule], fn ->
        html = render_layout(nil, @owner_scope)

        assert html =~ ~s(id="admin-drawer")
        refute html =~ "pk-test-bare-widget"
        refute html =~ "pk-dock"
      end)
    end

    test "a socket but no user: no widget, no dock, no crash" do
      with_registered([BareDockModule], fn ->
        html = render_layout(%Phoenix.LiveView.Socket{}, %{@owner_scope | user: nil})

        assert html =~ ~s(id="admin-drawer")
        refute html =~ "pk-test-bare-widget"
        refute html =~ "pk-dock"
      end)
    end
  end

  describe "PhoenixKitWeb.Components.AdminDock commands" do
    test "open, close and toggle address the class on #admin-drawer" do
      for {js, op} <- [
            {AdminDock.open(), "add_class"},
            {AdminDock.close(), "remove_class"},
            {AdminDock.toggle(), "toggle_class"}
          ] do
        assert [[^op, %{to: "#admin-drawer", names: ["pk-dock-open"]}]] = js.ops
      end
    end

    test "they chain onto an existing command" do
      js = JS.push("opened") |> AdminDock.open()

      assert [["push", _], ["add_class", _]] = js.ops
    end
  end
end
