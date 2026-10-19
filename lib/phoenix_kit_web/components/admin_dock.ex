defmodule PhoenixKitWeb.Components.AdminDock do
  @moduledoc """
  The optional right-hand dock column of the admin layout, and the commands that open it.

  A module's header widget (`c:PhoenixKit.Module.header_widgets/0`) that needs room beside
  the page, a chat panel for instance, declares `dock: true`. While at least one rendered
  widget does, `#admin-drawer` gets one more grid column, `#pk-dock`. Without such a widget
  the layout has no dock markup at all.

  ## Contract

    * **Container**: `#pk-dock` (`container_id/0`), the last child of `#admin-drawer`. It is
      an empty `<aside>` that is `display: none` until opened. What goes into it is the
      widget's business: the widget can position its own panel over the column (the column
      holds the width free, the panel sits at `right-0` with `w-[var(--pk-dock-width)]`), or
      move its panel element into the container with a hook.
    * **State**: the class `pk-dock-open` (`open_class/0`) on `#admin-drawer`
      (`drawer_id/0`). Set it with the JS commands below, not by hand. They are
      `Phoenix.LiveView.JS` class operations, which LiveView re-applies after every patch of
      the layout, so the dock stays open while the page changes under it. A full page load
      (another `live_session`) resets it; a widget that wants to survive that keeps the state
      in `localStorage` and replays `open/1` on mount.
    * **Width**: the CSS variable `--pk-dock-width` (`width_var/0`), `25rem` when unset. Set
      it on `#admin-drawer` or any ancestor, from CSS or a style attribute.
    * **Layout**: from `lg` up the dock is a third column of the drawer grid, so the work
      area gets narrower by the dock's width; the dock is as tall as the viewport below the
      header and scrolls itself. Below `lg` it covers the whole screen under the header.

  ## Commands

      <button phx-click={AdminDock.toggle()}>Chat</button>
      <button phx-click={AdminDock.close() |> JS.push("forget_panel")}>Close</button>

  The commands target `#admin-drawer` by selector, so they work from the widget's nested
  LiveView, which sits in the header.
  """

  alias Phoenix.LiveView.JS

  @drawer_id "admin-drawer"
  @container_id "pk-dock"
  @open_class "pk-dock-open"
  @width_var "--pk-dock-width"

  @doc "The id of the element that carries the open class."
  @spec drawer_id() :: String.t()
  def drawer_id, do: @drawer_id

  @doc "The id of the dock container."
  @spec container_id() :: String.t()
  def container_id, do: @container_id

  @doc "The class on the drawer while the dock is open."
  @spec open_class() :: String.t()
  def open_class, do: @open_class

  @doc "The CSS variable that sets the dock's width."
  @spec width_var() :: String.t()
  def width_var, do: @width_var

  @doc "Open the dock."
  @spec open(JS.t()) :: JS.t()
  def open(js \\ %JS{}), do: JS.add_class(js, @open_class, to: "#" <> @drawer_id)

  @doc "Close the dock."
  @spec close(JS.t()) :: JS.t()
  def close(js \\ %JS{}), do: JS.remove_class(js, @open_class, to: "#" <> @drawer_id)

  @doc "Open the dock if it is closed, close it if it is open."
  @spec toggle(JS.t()) :: JS.t()
  def toggle(js \\ %JS{}), do: JS.toggle_class(js, @open_class, to: "#" <> @drawer_id)
end
