defmodule PhoenixKitWeb.Components.MediaBrowser.View do
  @moduledoc """
  The media browser's template and the helpers it draws with.

  Split off `PhoenixKitWeb.Components.MediaBrowser` — the template alone
  took seconds to compile, and together with the component's event code the
  module regularly crossed the compiler's "taking more than 10s" notice.
  Two modules compile in parallel.

  `MediaBrowser.render/1` calls `browser/1` as a plain function with the
  component's own assigns, so change tracking is exactly what it was with
  the colocated template.

  The biggest parts of the template are function components in modules of
  their own — `MediaBrowser.Header` (the hero header and toolbar) and the
  three views, `MediaBrowser.GridView`, `MediaBrowser.StacksView` and
  `MediaBrowser.ListView` — each handed every assign it reads by name, so
  LiveView tracks them per value. What they draw with is
  `MediaBrowser.Helpers`.
  """
  use PhoenixKitWeb, :html

  import PhoenixKitWeb.Components.FolderExplorer,
    only: [
      folder_explorer: 1,
      folder_tree_node: 1
    ]

  import PhoenixKitWeb.Components.MediaBrowser.Helpers

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Utils.Format
  alias PhoenixKitWeb.Components.MediaBrowser

  embed_templates "browser.html"
end
