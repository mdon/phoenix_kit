defmodule PhoenixKitWeb.Components.Core.BulkSelect do
  @moduledoc """
  Bulk-select toolkit that composes with `<.table_default>`. Three
  function components, all opt-in — the consumer decides whether to
  render them and what events they emit.

    * `<.bulk_select_header_cell>` — drops into the table header in
      place of a `<.table_default_header_cell>`. Renders a tri-state
      checkbox via the `PkCheckboxIndeterminate` JS hook. State:

        0 selected      → unchecked
        partial         → indeterminate (—)
        all selected    → checked

      Clicking always emits `on_toggle`; the LV handler picks "all"
      or "none" based on current state.

    * `<.bulk_select_cell>` — drops into each row in place of a
      `<.table_default_cell>`. Renders a per-row checkbox bound to a
      uuid value.

    * `<.bulk_actions_toolbar>` — floating toolbar rendered ABOVE the
      table (sibling to `<.table_default>`, not nested). Shows the
      selection count + actions (Reorder, Delete, Clear). Reorder and
      Delete are gated by `allow_reorder_all` / `allow_delete` so
      consumers can hide them when they don't apply.

  Per-row checkboxes are consumer-wired (the row content varies per
  module). The header cell + toolbar are reusable shells.

  ## Example

      <.table_default id="projects-list" size="sm">
        <.table_default_header>
          <.table_default_row>
            <.bulk_select_header_cell
              :if={@bulk_enabled?}
              id="projects-select-all"
              selected_count={MapSet.size(@selected_uuids)}
              total_count={length(@projects)}
              on_toggle="toggle_select_all"
              aria_label={gettext("Select all projects")}
            />
            <.table_default_header_cell>Name</.table_default_header_cell>
            ...
          </.table_default_row>
        </.table_default_header>
        <tbody>
          <.table_default_row :for={p <- @projects}>
            <.bulk_select_cell
              :if={@bulk_enabled?}
              value={p.uuid}
              checked={MapSet.member?(@selected_uuids, p.uuid)}
              on_toggle="toggle_select"
            />
            <.table_default_cell>{p.name}</.table_default_cell>
            ...
          </.table_default_row>
        </tbody>
      </.table_default>

      <.bulk_actions_toolbar
        :if={@bulk_enabled? and @projects != []}
        selected_count={MapSet.size(@selected_uuids)}
        total_count={length(@projects)}
        on_open_reorder="open_reorder_modal"
        on_bulk_delete="bulk_delete"
        on_clear_selection="clear_selection"
        noun_plural={gettext("projects")}
        allow_delete={false}
      />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  @doc """
  Header checkbox cell — drop-in replacement for `<.table_default_header_cell>`
  in the bulk-select column.
  """
  attr :id, :string, required: true
  attr :selected_count, :integer, required: true
  attr :total_count, :integer, required: true
  attr :on_toggle, :string, required: true
  attr :aria_label, :string, default: "Toggle select all"
  attr :class, :string, default: "w-8"

  def bulk_select_header_cell(assigns) do
    ~H"""
    <th class={@class}>
      <input
        type="checkbox"
        id={@id}
        class="checkbox checkbox-sm"
        checked={@selected_count > 0 and @selected_count == @total_count}
        data-indeterminate={to_string(@selected_count > 0 and @selected_count < @total_count)}
        phx-hook="PkCheckboxIndeterminate"
        phx-click={@on_toggle}
        aria-label={@aria_label}
      />
    </th>
    """
  end

  @doc """
  Per-row checkbox cell — drop-in replacement for `<.table_default_cell>`
  in the bulk-select column. The `value` is forwarded as `phx-value-uuid`
  so the LV handler can identify which row was toggled.
  """
  attr :value, :string, required: true
  attr :checked, :boolean, required: true
  attr :on_toggle, :string, required: true
  attr :class, :string, default: "w-8"

  def bulk_select_cell(assigns) do
    ~H"""
    <td class={@class}>
      <input
        type="checkbox"
        class="checkbox checkbox-sm"
        checked={@checked}
        phx-click={@on_toggle}
        phx-value-uuid={@value}
      />
    </td>
    """
  end

  @doc """
  Floating toolbar above a bulk-selectable table. Shows selection count +
  actions. Renders when bulk mode is engaged on the consumer side (this
  component doesn't gate visibility — wrap with `:if={@bulk_enabled?}` or
  similar).

  Built-in actions: Reorder, Delete, Clear. Each is opt-in via flags so
  consumers can hide the buttons they don't need. The actions emit the
  events the consumer wires up — this component owns layout only.

  When `selected_count == 0`, only Reorder-all is shown (Delete + Clear
  hide). When > 0, Reorder flips to "Reorder selected" and Delete + Clear
  become visible.
  """
  attr :selected_count, :integer, required: true
  attr :total_count, :integer, required: true

  attr :on_open_reorder, :string, required: true
  attr :on_bulk_delete, :string, required: true
  attr :on_clear_selection, :string, required: true

  attr :noun_plural, :string, default: "items"
  attr :allow_reorder_all, :boolean, default: true
  attr :allow_delete, :boolean, default: true

  def bulk_actions_toolbar(assigns) do
    ~H"""
    <div class="flex items-center gap-3 bg-base-200 rounded-lg px-3 py-2 text-sm">
      <span class="text-base-content/70">
        <%= if @selected_count > 0 do %>
          {gettext("%{count} selected", count: @selected_count)}
        <% else %>
          {gettext("No selection")}
        <% end %>
      </span>

      <div class="flex items-center gap-2 ml-auto">
        <button
          :if={@allow_reorder_all or @selected_count > 0}
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click={@on_open_reorder}
          disabled={@total_count == 0}
        >
          <.icon name="hero-arrows-up-down" class="w-4 h-4" />
          {if @selected_count > 0,
            do: gettext("Reorder selected"),
            else: gettext("Reorder all")}
        </button>

        <button
          :if={@allow_delete and @selected_count > 0}
          type="button"
          class="btn btn-sm btn-ghost text-error"
          phx-click={@on_bulk_delete}
          data-confirm={
            gettext("Delete %{count} selected %{noun}? This cannot be undone.",
              count: @selected_count,
              noun: @noun_plural
            )
          }
        >
          <.icon name="hero-trash" class="w-4 h-4" />
          {gettext("Delete")}
        </button>

        <button
          :if={@selected_count > 0}
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click={@on_clear_selection}
        >
          {gettext("Clear")}
        </button>
      </div>
    </div>
    """
  end
end
