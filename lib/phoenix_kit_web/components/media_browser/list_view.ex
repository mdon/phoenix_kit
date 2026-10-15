defmodule PhoenixKitWeb.Components.MediaBrowser.ListView do
  @moduledoc false
  # The list view: folders and files as table rows.
  # Part of the media browser's template (`MediaBrowser.View`), in a module
  # of its own so the template compiles in parallel pieces. Every assign it
  # reads is passed in by name, so LiveView tracks its changes per value.
  use PhoenixKitWeb, :html

  import PhoenixKitWeb.Components.MediaBrowser.Helpers

  import PhoenixKitWeb.Components.FolderExplorer,
    only: [folder_color_hex: 1, folder_icon_style: 1, folder_bg_style: 1]

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Modules.Storage.ImageEditing

  embed_templates "list_view.html"
end
