defmodule PhoenixKitWeb.Components.Core.ContextMenu do
  @moduledoc """
  A desktop-style context menu: right-click (or touch-and-hold) any matching
  element to open an action menu at the pointer.

  One menu element serves every row it matches. A tree of five hundred nodes
  renders one hidden `<ul>`, not five hundred — the `ContextMenu` JS hook finds
  the row the pointer landed on, copies its identifier onto each item's
  `phx-value-*`, and opens the menu there. Opening costs no server round-trip,
  and the event that fires afterwards still carries the right target.

  ## Usage

  Mark the rows, then declare one menu that selects them:

      <li data-context-value={folder.uuid} data-context-label={folder.name}>
        …
      </li>

      <.context_menu id="folder-menu" selector="[data-context-value]" value_name="folder-uuid">
        <.context_menu_button phx-click="start_rename_folder" icon="hero-pencil" label="Rename" />
        <.context_menu_divider />
        <.context_menu_button phx-click="delete_folder" icon="hero-trash" label="Delete" variant="error" />
      </.context_menu>

  A right-click on that row opens the menu and the "Delete" item fires
  `delete_folder` with `%{"folder-uuid" => folder.uuid}` — the same param shape
  the row's own `phx-click` already uses, so handlers are shared rather than
  duplicated.

  ## Two menus on one page

  Declare one per row kind, each with its own `selector`:

      <.context_menu id="folder-menu" selector="[data-context-kind=folder]" …>
      <.context_menu id="note-menu"   selector="[data-context-kind=note]" …>

  When a click matches more than one (a note row nested inside a folder row),
  the **deepest** match wins — DOM order does not decide it. Use `within` to
  confine a menu to one region of the page when the same selector appears in
  several.

  ## Touch

  A press held for `long_press_ms` (default 450ms, cancelled by a 10px move)
  opens the menu at the touch point and vibrates briefly where supported. The
  click that follows the release is swallowed, so holding a row does not also
  activate it. Pass `long_press={false}` for a page whose touch gesture is
  already taken.

  > #### Long-press collides with MediaDragDrop {: .warning}
  >
  > `MediaDragDrop` binds its own 450ms long press to
  > `[data-draggable-file]` / `[data-draggable-folder]` and pushes
  > `long_press_select`. On a page running both, one hold fires both gestures.
  >
  > A *disjoint* selector is not enough: rows are matched with
  > `Element.closest/1`, so the two collide whenever one element merely
  > **contains** the other — and in `FolderExplorer` they do, both ways
  > (`data-draggable-folder` sits on a button inside the
  > `data-context-kind="folder"` row; a leaf `<li>` carries
  > `data-draggable-file` and `data-context-kind="item"` together). The
  > MediaBrowser sidebar is exactly this shape.
  >
  > There is a second effect worth knowing: this hook swallows the
  > post-long-press click at `document` capture, which is upstream of the
  > per-element listener `MediaDragDrop` uses to clear its own `_lpFired`
  > flag — so that flag stays set and eats one later tap on the same card.
  >
  > On a page running both, pass `long_press={false}` (right-click still
  > works) or don't wire `MediaDragDrop`.

  ## What items can do

  Items are buttons and links whose markup is `TableRowMenu`'s, so a context
  menu and a `⋮` row menu look identical. Only `phx-value-*` is stamped per
  row: an item's `navigate`/`href` is fixed at render time and cannot vary by
  target. For "open this one", use a button and `push_navigate/2` from the
  handler.

  ## Where the events land

  The menu is portaled to `<body>` while open, so `position: fixed` escapes any
  `<dialog>` or `transform`ed ancestor. LiveView routes clicks from an element
  outside every view root to the **main** LiveView, which is what a plain
  LiveView or a `phx-target`-carrying item wants. Inside a *nested* LiveView
  (a sticky one, say), pass an explicit `phx-target` on each item — the fallback
  would otherwise deliver to the main view.
  """

  use Phoenix.Component

  alias PhoenixKitWeb.Components.Core.TableRowMenu

  # ---------------------------------------------------------------------------
  # context_menu — the menu itself
  # ---------------------------------------------------------------------------

  @doc """
  Renders one context menu for every element matching `selector`.

  ## Attributes

  * `id` — unique element id (required); the hook attaches here.
  * `selector` — CSS selector for the elements that open this menu (required).
  * `within` — optional CSS selector confining `selector` to one container.
  * `value_attr` — row attribute holding the target's identifier
    (default `"data-context-value"`).
  * `value_name` — the `phx-value-*` suffix stamped onto items
    (default `"uuid"`, i.e. `phx-value-uuid`).
  * `label_attr` — row attribute holding a heading to show above the items
    (default `"data-context-label"`); the heading hides when the row has none.
  * `show_label` — render the heading slot at all (default `true`).
  * `long_press` / `long_press_ms` — the touch gesture (default `true` / `450`).
  * `label` — `aria-label` for the menu; pass a translated string.
  * `class` — extra classes for the floating `<ul>`.
  """
  attr :id, :string, required: true

  attr :selector, :string,
    required: true,
    doc: "CSS selector for the elements a right-click on which opens this menu."

  attr :within, :string,
    default: nil,
    doc: "Optional container selector; rows outside it are ignored."

  attr :value_attr, :string,
    default: "data-context-value",
    doc: "Row attribute read for the target identifier."

  attr :value_name, :any,
    default: "uuid",
    doc: """
    Stamped onto items as `phx-value-<value_name>`. A list stamps every name,
    for a menu whose items were written against handlers that spell the param
    differently (`"folder-uuid"` for one, `"folder_uuid"` for another).
    """

  attr :label_attr, :string,
    default: "data-context-label",
    doc: "Row attribute read for the menu heading."

  attr :show_label, :boolean, default: true
  attr :long_press, :boolean, default: true
  attr :long_press_ms, :integer, default: 450
  attr :label, :string, default: "Context menu"
  attr :class, :any, default: nil

  slot :inner_block, required: true

  def context_menu(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="ContextMenu"
      class="hidden"
      data-context-selector={@selector}
      data-context-within={@within}
      data-context-value-attr={@value_attr}
      data-context-value-name={value_names(@value_name)}
      data-context-label-attr={@show_label && @label_attr}
      data-context-long-press={to_string(@long_press)}
      data-context-long-press-ms={@long_press_ms}
    >
      <%!--
        Stable id: the hook portals this <ul> to <body> while open, so a server
        diff to the surrounding template makes morphdom re-create a duplicate
        here. `updated()` drops that duplicate, the same way RowMenu does.
      --%>
      <ul
        id={"#{@id}-content"}
        data-context-menu-content
        role="menu"
        aria-label={@label}
        tabindex="-1"
        class={[
          "hidden fixed z-[9999] min-w-[11rem] max-w-[18rem] rounded-box",
          "bg-base-100 border border-base-200 shadow-xl p-1 focus:outline-none",
          @class
        ]}
      >
        <%!-- Heading: the right-clicked row's name. Filled and unhidden by the
             hook, so it costs nothing when a row carries no label. --%>
        <li
          :if={@show_label}
          data-context-menu-label
          role="presentation"
          class="hidden px-3 py-1.5 text-xs font-semibold text-base-content/50 truncate"
        >
        </li>
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Items — TableRowMenu's markup, named for this context
  # ---------------------------------------------------------------------------

  @doc """
  An action item. Takes `phx-click` and friends through `rest`; the hook adds
  `phx-value-*` for the right-clicked row.

  See `PhoenixKitWeb.Components.Core.TableRowMenu.table_row_menu_button/1` —
  this is that component under a name that reads right inside a context menu.
  """
  attr :icon, :string, default: nil
  attr :label, :string, required: true
  attr :variant, :string, default: "default"
  attr :rest, :global

  def context_menu_button(assigns), do: TableRowMenu.table_row_menu_button(assigns)

  @doc """
  A navigation item with a fixed destination.

  `navigate`/`patch`/`href` are rendered once and do not vary per row — only
  `phx-value-*` is stamped. For a per-row destination use
  `context_menu_button/1` and navigate from the handler.
  """
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :string, default: nil
  attr :icon, :string, default: nil
  attr :label, :string, required: true
  attr :variant, :string, default: "default"
  attr :rest, :global, include: ~w(target rel method csrf_token data-confirm)

  def context_menu_link(assigns), do: TableRowMenu.table_row_menu_link(assigns)

  @doc "A separator between item groups."
  def context_menu_divider(assigns), do: TableRowMenu.table_row_menu_divider(assigns)

  # One name or several, as the comma-separated list the hook splits.
  defp value_names(names) when is_list(names), do: Enum.join(names, ",")
  defp value_names(name), do: name
end
