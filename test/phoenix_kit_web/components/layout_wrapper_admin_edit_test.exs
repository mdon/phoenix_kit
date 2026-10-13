defmodule PhoenixKitWeb.Components.LayoutWrapperAdminEditTest do
  @moduledoc """
  `app_layout/1` carries the page's "Edit" target (`:admin_edit_url` /
  `:admin_edit_label`, set by `AdminEditHelper.assign_admin_edit/3`) into the
  account menu of the admin chrome and into a host layout.

  Before this, only the dashboard layout read the two assigns; a page rendered
  through `app_layout/1` dropped them. An explicit `module_assigns` entry must
  keep beating the passed-through pair.

  DB-free: scopes are literal structs and every setting the layout reads is
  passed in as an assign.
  """
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Permissions
  alias PhoenixKitWeb.Components.LayoutWrapper

  defmodule HostLayout do
    use Phoenix.Component

    def frontend(assigns) do
      ~H"""
      <div
        id="host-shell"
        data-edit-url={assigns[:admin_edit_url]}
        data-edit-label={assigns[:admin_edit_label]}
      >
        {@inner_content}
      </div>
      """
    end
  end

  defp scope(roles, permissions) do
    %Scope{
      user: %User{uuid: "0193a5e4-0000-7000-8000-0000000000e1", email: "head@example.com"},
      authenticated?: true,
      cached_roles: roles,
      cached_permissions: MapSet.new(permissions)
    }
  end

  defp owner_scope, do: scope(["Owner"], Permissions.all_module_keys())
  defp plain_user_scope, do: scope(["User"], [])

  defp render_layout(opts) do
    assigns = %{
      scope: Keyword.get(opts, :scope, owner_scope()),
      current_path: Keyword.get(opts, :current_path, "/admin/things"),
      url: Keyword.get(opts, :url),
      label: Keyword.get(opts, :label),
      module_assigns: Keyword.get(opts, :module_assigns, %{})
    }

    ~H"""
    <LayoutWrapper.app_layout
      flash={%{}}
      current_path={@current_path}
      page_title="Thing"
      project_title="Acme"
      show_admin_panel_label={true}
      show_page_descriptions={false}
      dev_environment={false}
      current_locale="en"
      phoenix_kit_current_scope={@scope}
      admin_edit_url={@url}
      admin_edit_label={@label}
      module_assigns={@module_assigns}
    >
      <span id="pk-test-body">body</span>
    </LayoutWrapper.app_layout>
    """
    |> rendered_to_string()
  end

  # The account menu's entries, in document order.
  defp menu_hrefs(html) do
    [menu] = Regex.run(~r/<ul[^>]*id="pk-admin-account-menu".*?<\/ul>/s, html)
    Regex.scan(~r/<a [^>]*href="([^"]+)"/, menu) |> Enum.map(&List.last/1)
  end

  describe "admin chrome" do
    test "the Edit entry is the first item of the account menu" do
      html = render_layout(url: "/admin/things/42/edit", label: "Edit thing")

      assert [first, second | _] = menu_hrefs(html)
      assert first == "/admin/things/42/edit"
      assert second =~ "settings"
      assert html =~ "Edit thing"
    end

    test "the label falls back to the translated default" do
      html = render_layout(url: "/admin/things/42/edit")

      assert hd(menu_hrefs(html)) == "/admin/things/42/edit"
      assert html =~ "<span>Edit</span>"
    end

    test "no URL, no entry" do
      html = render_layout([])

      refute "/admin/things/42/edit" in menu_hrefs(html)
      refute html =~ "hero-pencil-square"
    end

    test "a scope that cannot reach the admin area gets no entry, whatever was assigned" do
      html = render_layout(scope: plain_user_scope(), url: "/admin/things/42/edit")

      refute html =~ "/admin/things/42/edit"
    end

    test "an explicit module_assigns entry beats the passed-through pair, label included" do
      html =
        render_layout(
          url: "/admin/page/edit",
          label: "Page label",
          module_assigns: %{
            admin_edit_url: "/admin/module/edit",
            admin_edit_label: "Module label"
          }
        )

      assert hd(menu_hrefs(html)) == "/admin/module/edit"
      assert html =~ "Module label"
      refute html =~ "/admin/page/edit"
      refute html =~ "Page label"
    end

    test "module_assigns alone still works" do
      html = render_layout(module_assigns: %{admin_edit_url: "/admin/module/edit"})

      assert hd(menu_hrefs(html)) == "/admin/module/edit"
    end
  end

  describe "host layout" do
    setup do
      previous = Application.get_all_env(:phoenix_kit)

      Application.put_env(:phoenix_kit, :phoenix_version_strategy, :modern)
      Application.put_env(:phoenix_kit, :layout, {HostLayout, :frontend})

      on_exit(fn ->
        for key <- [:phoenix_version_strategy, :layout] do
          case Keyword.fetch(previous, key) do
            {:ok, value} -> Application.put_env(:phoenix_kit, key, value)
            :error -> Application.delete_env(:phoenix_kit, key)
          end
        end
      end)
    end

    test "receives the pair as top-level assigns" do
      html =
        render_layout(current_path: "/shop", url: "/admin/things/42/edit", label: "Edit thing")

      assert html =~ ~s(id="host-shell")
      assert html =~ ~s(data-edit-url="/admin/things/42/edit")
      assert html =~ ~s(data-edit-label="Edit thing")
    end

    test "an explicit module_assigns entry still reaches it, and wins" do
      html =
        render_layout(
          current_path: "/shop",
          url: "/admin/page/edit",
          module_assigns: %{admin_edit_url: "/admin/module/edit"}
        )

      assert html =~ ~s(data-edit-url="/admin/module/edit")
    end

    test "without a URL the layout sees none" do
      html = render_layout(current_path: "/shop")

      refute html =~ "data-edit-url"
    end
  end
end
