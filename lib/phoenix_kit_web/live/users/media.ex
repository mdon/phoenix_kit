defmodule PhoenixKitWeb.Live.Users.Media do
  @moduledoc """
  Media management LiveView — thin wrapper around `MediaBrowser` LiveComponent.

  This LiveView owns the page layout and assigns required by
  `LayoutWrapper.app_layout`. All media browser state and logic live in
  `PhoenixKitWeb.Components.MediaBrowser`.

  URL sync (shareable `…/admin/media?folder=<uuid>` deep links) is provided
  by the `MediaBrowser.Embed` macro's `url_sync` option — it injects the
  `handle_params` / `{:navigate}` → `push_patch` round-trip and parses
  `:initial_params` from the URL in `on_mount`, so this module only owns
  the page-chrome assigns.

  ## Libraries

  The page shows one **system library** at a time
  (`PhoenixKit.Modules.Storage.Libraries`): the default one (Media) at the
  bare `/admin/media`, any other at `/admin/media/library/<slug>`. While
  Media is the only one, nothing about libraries is shown and the browser
  is given no library at all — it lists exactly what it listed before
  libraries existed. Libraries are created, renamed and deleted in Settings
  → Media → Libraries (`PhoenixKitWeb.Live.Modules.Storage.LibrariesComponent`).
  """
  use PhoenixKitWeb, :live_view
  use PhoenixKitWeb.Components.MediaBrowser.Embed, url_sync: [id: "media-browser"]

  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale]

    settings =
      Settings.get_settings_cached(
        ["project_title"],
        %{"project_title" => PhoenixKit.Config.get(:project_title, "PhoenixKit")}
      )

    socket =
      socket
      |> assign(:page_title, gettext("Media"))
      |> assign(:project_title, settings["project_title"])
      |> assign(:current_locale, locale)
      |> assign(:url_path, Routes.path("/admin/media"))
      |> assign(:libraries, nil)
      |> assign(:library, nil)

    {:ok, socket}
  end

  # The libraries are read once per page, not on every folder navigation
  # (each one is a patch through here).
  def handle_params(params, _uri, socket) do
    socket = if socket.assigns.libraries, do: socket, else: load_libraries(socket)

    case select_library(socket, params["library_slug"]) do
      {:ok, socket} ->
        {:noreply, socket}

      # A slug that names no live library is not quietly shown as Media — an
      # upload there would land somewhere the visitor did not ask for.
      :not_found ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Library not found"))
         |> push_patch(to: library_path(nil))}
    end
  end

  # Only a library the page listed: the slug arrives from the client and ends
  # up in a path.
  def handle_event("switch_library", %{"library" => slug}, socket) do
    case Enum.find(socket.assigns.libraries || [], &((&1.slug || "") == slug)) do
      nil -> {:noreply, socket}
      library -> {:noreply, push_patch(socket, to: library_path(library.slug))}
    end
  end

  defp load_libraries(socket), do: assign(socket, :libraries, Libraries.list_system_libraries())

  # The bare page is the default library; `/library/<slug>` another live
  # system library. A slug that names none is `:not_found`.
  defp select_library(socket, slug) when slug in [nil, ""] do
    libraries = socket.assigns.libraries

    {:ok,
     assign(socket, :library, Enum.find(libraries, & &1.is_default) || List.first(libraries))}
  end

  defp select_library(socket, slug) do
    case Enum.find(socket.assigns.libraries, &(&1.slug == slug)) do
      nil -> :not_found
      library -> {:ok, assign(socket, :library, library)}
    end
  end

  # Switching library opens it at its root: no folder, search or page from
  # the other one carries over. The default library is the bare page.
  defp library_path(slug) when slug in [nil, ""], do: Routes.path("/admin/media")
  defp library_path(slug), do: Routes.path("/admin/media/library/#{slug}")

  @doc false
  # The library the browser is given: nil while only one exists, so the
  # listing is exactly the pre-library one.
  def browser_library_uuid(libraries, library) do
    if is_list(libraries) and length(libraries) > 1 and library, do: library.uuid
  end
end
