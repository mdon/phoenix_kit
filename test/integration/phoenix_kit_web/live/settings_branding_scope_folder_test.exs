defmodule PhoenixKitWeb.Live.SettingsBrandingScopeFolderTest do
  @moduledoc """
  The settings page's logo/site-icon `MediaSelectorModal` receives
  `scope_folder_id` from `PhoenixKit.UploadsParentFolder.resolve(:branding, ...)`
  (media hierarchy phase 2, plan 8, task 2).
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings")

  # `mount/3` runs in the LiveView's own process, not the test process, so
  # the hook's answer has to travel through something process-independent
  # (`Application` env) rather than the test's `Process` dictionary.
  defmodule Hook do
    @moduledoc false
    def parent_for(:branding, _actor_uuid, _subject) do
      if pid = Application.get_env(:phoenix_kit, :branding_scope_folder_test_pid) do
        send(pid, :branding_hook_called)
      end

      {:ok, Application.get_env(:phoenix_kit, :branding_scope_folder_test_folder_uuid)}
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :uploads_parent_folder)
      Application.delete_env(:phoenix_kit, :branding_scope_folder_test_folder_uuid)
      Application.delete_env(:phoenix_kit, :branding_scope_folder_test_pid)
    end)

    :ok
  end

  # A host hook may lazily create its folder, so a page view that never opens
  # the selector must not consult it (mount also runs twice).
  test "the hook is consulted when the selector opens, not on mount", %{conn: conn} do
    {user, _token} = create_admin_user()
    conn = log_in_user(conn, user)

    {:ok, folder} =
      Storage.create_folder(%{name: "Branding #{System.unique_integer([:positive])}"})

    Application.put_env(:phoenix_kit, :branding_scope_folder_test_folder_uuid, folder.uuid)
    Application.put_env(:phoenix_kit, :branding_scope_folder_test_pid, self())
    Application.put_env(:phoenix_kit, :uploads_parent_folder, {Hook, :parent_for})

    {:ok, view, _html} = live(conn, @path)
    refute_received :branding_hook_called

    render_click(view, "open_media_selector", %{"target" => "logo"})
    assert_received :branding_hook_called
  end

  test "hook set: the modal carries data-scope-folder for the resolved folder", %{conn: conn} do
    {user, _token} = create_admin_user()
    conn = log_in_user(conn, user)

    {:ok, folder} =
      Storage.create_folder(%{name: "Branding #{System.unique_integer([:positive])}"})

    Application.put_env(:phoenix_kit, :branding_scope_folder_test_folder_uuid, folder.uuid)
    Application.put_env(:phoenix_kit, :uploads_parent_folder, {Hook, :parent_for})

    {:ok, view, _html} = live(conn, @path)

    render_click(view, "open_media_selector", %{"target" => "logo"})

    assert has_element?(view, "[data-scope-folder='#{folder.uuid}']")
  end

  test "no hook configured: the modal carries no scope folder", %{conn: conn} do
    {user, _token} = create_admin_user()
    conn = log_in_user(conn, user)

    {:ok, view, _html} = live(conn, @path)

    render_click(view, "open_media_selector", %{"target" => "logo"})

    refute has_element?(view, "[data-scope-folder]")
  end
end
