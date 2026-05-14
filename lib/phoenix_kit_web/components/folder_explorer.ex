defmodule PhoenixKitWeb.Components.FolderExplorer do
  @moduledoc """
  Reusable folder explorer sidebar — folder tree, navigation buttons,
  inline rename, and (optional) Trash / All Files / New Folder controls.

  Extracted from `PhoenixKitWeb.Components.MediaBrowser` so other LiveViews
  can embed folder navigation (folder pickers, category browsers, etc.)
  without duplicating the markup.

  ## Ownership model

  Pure presentation function component. The consumer owns all state and
  event handlers; FolderExplorer just renders. Every interactive control
  fires `phx-target={@myself}` back to the consumer, so the consumer must
  implement the relevant `handle_event/3` clauses:

      navigate_folder, navigate_root, navigate_view_all,
      toggle_folder_expand, toggle_sidebar, create_untitled_folder,
      start_rename_folder, rename_folder_input, rename_folder,
      cancel_rename_folder, toggle_trash_filter

  The drag-drop data attributes (`data-drop-folder`, `data-draggable-folder`,
  `data-drop-trash`) are present unconditionally; consumers that wire up the
  `MediaDragDrop` JS hook get drag-drop for free, others can ignore them.

  ## Usage

      <.folder_explorer
        id="my-folder-explorer"
        myself={@myself}
        folder_tree={@folder_tree}
        current_folder={@current_folder}
        expanded_folders={@expanded_folders}
        scope_folder_id={@scope_folder_id}
        scope_folder_name={@scope_folder_name}
        renaming_folder={@renaming_folder}
        renaming_source={@renaming_source}
        renaming_text={@renaming_text}
        filter_trash={@filter_trash}
        file_view={@file_view}
        sidebar_collapsed={@sidebar_collapsed}
        trash_count={@trash_count}
      />

  ## Config flags

  - `show_create` (default `true`) — show the `+` toolbar button.
  - `show_all_files` (default `true`) — show the "All Files" flat-view button
    (only renders when `scope_folder_id` is `nil`; the flag gates that branch).
  - `show_trash` (default `true`) — show the Trash button + badge.

  Folder-color helpers (`folder_color_hex/1`, `folder_icon_style/2`,
  `folder_bg_style/1`) live here too since the sidebar and the grid/list
  folder cards in MediaBrowser both consume them.
  """

  use PhoenixKitWeb, :html

  alias Phoenix.LiveView.JS

  # ──────────────────────────────────────────────────────────────
  # Top-level component
  # ──────────────────────────────────────────────────────────────

  attr :id, :string, default: "folder-explorer"
  attr :myself, :any, required: true

  attr :folder_tree, :any, required: true
  attr :current_folder, :any, default: nil
  attr :expanded_folders, :any, required: true
  attr :scope_folder_id, :any, default: nil
  attr :scope_folder_name, :string, default: "Root"

  attr :renaming_folder, :any, default: nil
  attr :renaming_source, :any, default: nil
  attr :renaming_text, :string, default: ""

  attr :filter_trash, :boolean, default: false
  attr :file_view, :string, default: nil

  attr :sidebar_collapsed, :boolean, default: false
  attr :trash_count, :integer, default: 0

  attr :show_create, :boolean, default: true
  attr :show_all_files, :boolean, default: true
  attr :show_trash, :boolean, default: true

  def folder_explorer(assigns) do
    ~H"""
    <div
      id={@id}
      class="hidden lg:block shrink-0"
      style={if !@sidebar_collapsed, do: "width: 240px; max-width: 240px;"}
    >
      <%= if @sidebar_collapsed do %>
        <%!-- Collapsed strip --%>
        <div class="sticky top-4 w-10">
          <button
            phx-click="toggle_sidebar"
            phx-target={@myself}
            class="btn btn-ghost btn-sm w-full"
            title={gettext("Show folders")}
          >
            <.icon name="hero-chevron-right" class="w-4 h-4" />
          </button>
        </div>
      <% else %>
        <%!-- Expanded sidebar --%>
        <div
          class="sticky top-4 border-r border-base-200 pr-3 mr-3 overflow-hidden"
          style="width: 240px; max-width: 240px;"
        >
          <div class="flex items-center justify-between mb-3">
            <%= if is_nil(@scope_folder_id) do %>
              <h3 class="font-semibold text-sm text-base-content/70 uppercase tracking-wider">
                {gettext("Folders")}
              </h3>
            <% else %>
              <div></div>
            <% end %>
            <div class="flex gap-0.5">
              <button
                :if={@show_create}
                phx-click="create_untitled_folder"
                phx-target={@myself}
                class="btn btn-ghost btn-xs"
                title={gettext("New folder")}
              >
                <.icon name="hero-folder-plus" class="w-4 h-4" />
              </button>
              <button
                phx-click="toggle_sidebar"
                phx-target={@myself}
                class="btn btn-ghost btn-xs"
                title={gettext("Collapse sidebar")}
              >
                <.icon name="hero-chevron-left" class="w-4 h-4" />
              </button>
            </div>
          </div>

          <%!-- All Files flat view (only when unscoped — admin media page) --%>
          <%= if @show_all_files and is_nil(@scope_folder_id) do %>
            <button
              phx-click="navigate_view_all"
              phx-target={@myself}
              class={[
                "flex items-center gap-2 w-full px-2 py-1.5 rounded-lg text-sm transition-colors mb-1 text-left",
                if(@file_view == "all" and not @filter_trash,
                  do: "bg-primary/10 font-semibold text-primary",
                  else: "hover:bg-base-200"
                )
              ]}
            >
              <.icon name="hero-rectangle-stack" class="w-4 h-4 shrink-0" /> {gettext("All Files")}
            </button>
          <% end %>

          <%!-- Root (navigate to real root folder) --%>
          <button
            phx-click="navigate_root"
            phx-target={@myself}
            data-drop-folder="root"
            class={[
              "flex items-center gap-2 w-full px-2 py-1.5 rounded-lg text-sm transition-colors mb-1 text-left",
              if(@current_folder == nil and @file_view != "all" and not @filter_trash,
                do: "bg-primary/10 font-semibold text-primary",
                else: "hover:bg-base-200"
              )
            ]}
          >
            <.icon name="hero-inbox" class="w-4 h-4 shrink-0" /> {@scope_folder_name}
          </button>

          <div class="divider my-1 h-0"></div>

          <%!-- Folder Tree --%>
          <ul class="space-y-0.5 w-full overflow-hidden">
            <%= for node <- @folder_tree do %>
              <.folder_tree_node
                node={node}
                current_folder={@current_folder}
                expanded_folders={@expanded_folders}
                renaming_folder={@renaming_folder}
                renaming_source={@renaming_source}
                renaming_text={@renaming_text}
                filter_trash={@filter_trash}
                depth={0}
                myself={@myself}
              />
            <% end %>
          </ul>

          <%!-- Trash --%>
          <%= if @show_trash do %>
            <div class="divider my-1 h-0"></div>
            <button
              phx-click="toggle_trash_filter"
              phx-target={@myself}
              data-drop-trash="true"
              class={[
                "flex items-center gap-2 px-2 py-1.5 rounded-lg text-sm transition-colors w-full",
                if(@filter_trash,
                  do: "bg-error/10 font-semibold text-error",
                  else: "hover:bg-base-200 text-base-content/60"
                )
              ]}
            >
              <.icon name="hero-trash" class="w-4 h-4 shrink-0" /> {gettext("Trash")}
              <%= if @trash_count > 0 do %>
                <span class="badge badge-sm badge-error ml-auto">{@trash_count}</span>
              <% end %>
            </button>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ──────────────────────────────────────────────────────────────
  # Recursive tree node
  # ──────────────────────────────────────────────────────────────

  attr :node, :map, required: true
  attr :current_folder, :any, required: true
  attr :expanded_folders, :any, required: true
  attr :renaming_folder, :any, required: true
  attr :renaming_text, :string, default: ""
  attr :renaming_source, :any, required: true
  attr :filter_trash, :boolean, default: false
  attr :depth, :integer, default: 0
  attr :myself, :any, required: true

  def folder_tree_node(assigns) do
    # In trash view no folder is "active" in the file sense — the user is
    # looking at trashed files, not a folder's contents. We keep
    # `@current_folder` populated in the socket so toggling trash off
    # restores the previous folder, but the tree highlight is suppressed
    # while filter_trash is on (the sidebar Trash button carries the
    # active highlight instead).
    assigns =
      assign(
        assigns,
        :is_active,
        (not assigns.filter_trash and assigns.current_folder) &&
          assigns.current_folder.uuid == assigns.node.folder.uuid
      )

    assigns =
      assign(
        assigns,
        :is_expanded,
        MapSet.member?(assigns.expanded_folders, assigns.node.folder.uuid)
      )

    assigns = assign(assigns, :has_children, assigns.node.children != [])

    assigns =
      assign(
        assigns,
        :is_renaming,
        assigns.renaming_folder == assigns.node.folder.uuid &&
          assigns.renaming_source == "sidebar"
      )

    ~H"""
    <li class="overflow-hidden">
      <div
        class={[
          "flex items-center gap-0.5 rounded-lg px-1 py-1 hover:bg-base-200 transition-colors group overflow-hidden min-w-0",
          @is_active && "font-semibold"
        ]}
        style={
          if @is_active,
            do: "background-color: #{folder_color_hex(@node.folder.color) || "oklch(var(--p))"}25"
        }
      >
        <%!-- Chevron (expand/collapse) --%>
        <%= if @has_children do %>
          <button
            phx-click="toggle_folder_expand"
            phx-target={@myself}
            phx-value-folder-uuid={@node.folder.uuid}
            class="btn btn-ghost btn-xs p-0 min-h-0 h-5 w-5"
          >
            <.icon
              name={if @is_expanded, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"}
              class="w-4 h-4 text-base-content/40"
            />
          </button>
        <% else %>
          <span class="w-5"></span>
        <% end %>

        <%= if @is_renaming do %>
          <%!-- Inline rename form --%>
          <form
            phx-submit="rename_folder"
            phx-change="rename_folder_input"
            phx-target={@myself}
            class="flex items-center gap-1.5 flex-1 min-w-0"
          >
            <input type="hidden" name="folder_uuid" value={@node.folder.uuid} />
            <span style={folder_icon_style(@node.folder.color)}>
              <.icon name="hero-folder" class="w-4 h-4 shrink-0" />
            </span>
            <%!--
              Minimal bordered input — pairs with the row's
              `ring-2 ring-primary` above. Sits flush with the row's
              natural height (no daisyUI `input input-bordered input-xs`
              chunkiness) and uses a thin primary border + white bg so
              it reads as "edit field" without overwhelming the row.
            --%>
            <input
              type="text"
              name="name"
              value={@renaming_text}
              class="bg-base-100 text-sm rounded px-1.5 py-0 flex-1 min-w-0 border border-primary/60 focus:outline-none focus:border-primary"
              phx-mounted={JS.focus()}
              required
              phx-keydown="cancel_rename_folder"
              phx-key="Escape"
              phx-blur="cancel_rename_folder"
              phx-target={@myself}
              phx-debounce="50"
            />
          </form>
        <% else %>
          <%!-- Folder button (uncontrolled: phx-click instead of .link navigate) --%>
          <button
            phx-click="navigate_folder"
            phx-target={@myself}
            phx-value-folder-uuid={@node.folder.uuid}
            data-drop-folder={@node.folder.uuid}
            data-draggable-folder={@node.folder.uuid}
            class="flex items-center gap-1.5 flex-1 min-w-0 overflow-hidden text-sm text-left"
          >
            <span style={folder_icon_style(@node.folder.color, @is_active)}>
              <.icon
                name={if @is_expanded, do: "hero-folder-open", else: "hero-folder"}
                class="w-4 h-4 shrink-0"
              />
            </span>
            <span
              class={[
                "truncate block min-w-0",
                @renaming_folder == @node.folder.uuid && !@is_renaming && "renaming-preview"
              ]}
              title={@node.folder.name}
            >
              <%= if @renaming_folder == @node.folder.uuid && @renaming_text != "" do %>
                {@renaming_text}
              <% else %>
                {@node.folder.name}
              <% end %>
            </span>
          </button>
          <%!-- Rename button (visible on hover) --%>
          <button
            phx-click="start_rename_folder"
            phx-target={@myself}
            phx-value-folder-uuid={@node.folder.uuid}
            phx-value-source="sidebar"
            class="btn btn-ghost btn-xs p-0 min-h-0 h-5 w-5 opacity-0 group-hover:opacity-100"
            title={gettext("Rename")}
          >
            <.icon name="hero-pencil" class="w-3 h-3 text-base-content/40" />
          </button>
        <% end %>
      </div>

      <%!-- Children (expanded) --%>
      <%= if @has_children && @is_expanded do %>
        <ul
          class="ml-3 border-l-2 pl-1 overflow-hidden"
          style={"border-color: #{folder_color_hex(@node.folder.color) || "oklch(var(--bc) / 0.15)"}"}
        >
          <%= for child <- @node.children do %>
            <.folder_tree_node
              node={child}
              current_folder={@current_folder}
              expanded_folders={@expanded_folders}
              renaming_folder={@renaming_folder}
              renaming_source={@renaming_source}
              renaming_text={@renaming_text}
              filter_trash={@filter_trash}
              depth={@depth + 1}
              myself={@myself}
            />
          <% end %>
        </ul>
      <% end %>
    </li>
    """
  end

  # ──────────────────────────────────────────────────────────────
  # Folder color helpers (shared with grid/list folder cards)
  # ──────────────────────────────────────────────────────────────

  def folder_bg_style(color) do
    case folder_color_hex(color) do
      nil -> nil
      hex -> "background-color: #{hex}15"
    end
  end

  def folder_icon_style(color, _active? \\ false) do
    case folder_color_hex(color) do
      nil -> "color: oklch(var(--wa))"
      hex -> "color: #{hex}"
    end
  end

  def folder_color_hex("red"), do: "#ef4444"
  def folder_color_hex("orange"), do: "#f97316"
  def folder_color_hex("amber"), do: "#f59e0b"
  def folder_color_hex("yellow"), do: "#eab308"
  def folder_color_hex("lime"), do: "#84cc16"
  def folder_color_hex("green"), do: "#22c55e"
  def folder_color_hex("emerald"), do: "#10b981"
  def folder_color_hex("teal"), do: "#14b8a6"
  def folder_color_hex("cyan"), do: "#06b6d4"
  def folder_color_hex("sky"), do: "#0ea5e9"
  def folder_color_hex("blue"), do: "#3b82f6"
  def folder_color_hex("violet"), do: "#8b5cf6"
  def folder_color_hex("purple"), do: "#a855f7"
  def folder_color_hex("fuchsia"), do: "#d946ef"
  def folder_color_hex("pink"), do: "#ec4899"
  def folder_color_hex("rose"), do: "#f43f5e"
  def folder_color_hex(_), do: nil
end
