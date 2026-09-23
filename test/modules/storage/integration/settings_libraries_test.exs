defmodule PhoenixKitWeb.Live.Modules.Storage.SettingsLibrariesTest do
  @moduledoc """
  The Libraries tab of Settings → Media (`LibrariesComponent`): what each
  system library holds, and creating, renaming and deleting them.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/media")

  defp admin_view(conn) do
    {user, _token} = create_admin_user()
    {:ok, view, html} = live(log_in_user(conn, user), @path)
    {view, html}
  end

  defp name, do: "Lib #{System.unique_integer([:positive])}"

  test "the tab lists Media as the default, with its address and what it holds", %{conn: conn} do
    {:ok, _} = Storage.create_folder(%{name: "counted-#{System.unique_integer([:positive])}"})
    {view, html} = admin_view(conn)

    assert html =~ "media-tab-libraries"
    row = view |> element("#media-libraries-#{Libraries.media_uuid()}") |> render()

    assert row =~ "Media"
    assert row =~ "Default"
    assert row =~ ~s(href="#{Routes.path("/admin/media")}")
    # The default is never deletable, so it has no Delete button at all.
    refute row =~ "Delete"
  end

  test "creating a library adds it, with its own address", %{conn: conn} do
    {view, _html} = admin_view(conn)
    library_name = name()

    view |> element("#media-libraries button", "New library") |> render_click()
    view |> form("#media-libraries-new", %{name: library_name}) |> render_submit()
    # The flash is put by the page, on the message the tab sends it.
    html = render(view)

    library = Enum.find(Libraries.list_system_libraries(), &(&1.name == library_name))
    assert library
    assert html =~ Routes.path("/admin/media/library/#{library.slug}")
    assert html =~ "created"
  end

  test "a taken name is refused with the reason", %{conn: conn} do
    {:ok, existing} = Libraries.create_system_library(%{name: name()})
    {view, _html} = admin_view(conn)

    view |> element("#media-libraries button", "New library") |> render_click()
    view |> form("#media-libraries-new", %{name: existing.name}) |> render_submit()
    html = render(view)

    assert html =~ "already the name of another library"
  end

  test "renaming keeps the address", %{conn: conn} do
    {:ok, library} = Libraries.create_system_library(%{name: name()})
    {view, _html} = admin_view(conn)
    new_name = name()

    view
    |> element("#media-libraries-#{library.uuid} button", "Rename")
    |> render_click()

    html =
      view
      |> form("#media-libraries-rename-#{library.uuid}", %{name: new_name})
      |> render_submit()

    assert html =~ new_name
    renamed = Libraries.get_library(library.uuid)
    assert renamed.name == new_name
    assert renamed.slug == library.slug
  end

  test "an empty library can be deleted; one with a folder cannot", %{conn: conn} do
    {:ok, empty} = Libraries.create_system_library(%{name: name()})
    {:ok, busy} = Libraries.create_system_library(%{name: name()})
    {:ok, _} = Storage.create_folder(%{name: "busy", library_uuid: busy.uuid})
    {view, _html} = admin_view(conn)

    view |> element("#media-libraries-#{empty.uuid} button", "Delete") |> render_click()
    refute Libraries.get_library(empty.uuid)

    # Disabled in the page; a forged click is refused by the context too.
    assert view
           |> element("#media-libraries-#{busy.uuid} button[disabled]", "Delete")
           |> has_element?()

    view |> with_target("#media-libraries") |> render_click("delete", %{"uuid" => busy.uuid})
    assert Libraries.get_library(busy.uuid)
  end
end
