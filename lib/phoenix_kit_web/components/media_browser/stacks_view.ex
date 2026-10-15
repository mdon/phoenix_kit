defmodule PhoenixKitWeb.Components.MediaBrowser.StacksView do
  @moduledoc false
  # The stacks view: folders as fanned-out piles that expand in place.
  # Part of the media browser's template (`MediaBrowser.View`), in a module
  # of its own so the template compiles in parallel pieces. Every assign it
  # reads is passed in by name, so LiveView tracks its changes per value.
  use PhoenixKitWeb, :html

  import PhoenixKitWeb.Components.MediaBrowser.Helpers

  embed_templates "stacks_view.html"
end
