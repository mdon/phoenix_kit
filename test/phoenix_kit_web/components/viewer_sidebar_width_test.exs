defmodule PhoenixKitWeb.Components.ViewerSidebarWidthTest do
  @moduledoc """
  The viewer's info sidebar is flex-[3] of the popup — fine on a laptop,
  but on a 4K display 30% of a 95vw modal is ~1100px of mostly empty
  white, and the image column's seam (with the step arrows anchored to
  it) drifts toward the middle of the popup. A max-width caps it, so
  big displays give the extra room to the image.

  The stand-in's skeleton pane exists to predict the real image/sidebar
  split during the open hand-off — the two must carry the SAME cap, or
  4K opens jump at hand-off.

  Since #874 the side split, and so its cap, is `lg:landscape:` only: a
  portrait window stacks the panel under the picture instead.
  """

  use ExUnit.Case, async: true

  @viewer Path.expand(
            "../../../lib/phoenix_kit_web/components/media_canvas_viewer.html.heex",
            __DIR__
          )
  @standin Path.expand(
             "../../../lib/phoenix_kit_web/components/media_browser.html.heex",
             __DIR__
           )

  test "the real sidebar and the stand-in's pane share one width cap" do
    viewer = File.read!(@viewer)
    standin = File.read!(@standin)

    [_, real] = Regex.run(~r/data-viewer-sidebar\s+class="([^"]*)"/, viewer)
    [_, pane] = Regex.run(~r/data-pane="sidebar"\s+class="([^"]*)"/, standin)

    assert real =~ "lg:landscape:max-w-", "an uncapped flex-[3] sidebar eats a 4K popup"
    [cap] = Regex.run(~r/lg:landscape:max-w-\S+/, real)
    assert pane =~ cap, "the stand-in must predict the real split — same cap, or 4K opens jump"
    assert real =~ "lg:landscape:min-w-[280px]"
    assert pane =~ "lg:landscape:min-w-[280px]"
  end
end
