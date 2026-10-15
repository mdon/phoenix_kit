defmodule PhoenixKitWeb.Components.MediaBrowser.Header do
  @moduledoc false
  # The hero header: cover/gradient, title, creation info and the toolbar.
  # Part of the media browser's template (`MediaBrowser.View`), in a module
  # of its own so the template compiles in parallel pieces. Every assign it
  # reads is passed in by name, so LiveView tracks its changes per value.
  use PhoenixKitWeb, :html

  import PhoenixKitWeb.Components.MediaBrowser.Helpers

  import PhoenixKitWeb.Components.FolderExplorer,
    only: [folder_color_hex: 1]

  alias Phoenix.LiveView.JS

  embed_templates "header.html"
end
