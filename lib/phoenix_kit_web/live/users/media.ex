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
  """
  use PhoenixKitWeb, :live_view
  use PhoenixKitWeb.Components.MediaBrowser.Embed, url_sync: [id: "media-browser"]

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

    {:ok, socket}
  end
end
