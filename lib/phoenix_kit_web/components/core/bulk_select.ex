defmodule PhoenixKitWeb.Components.Core.BulkSelect do
  @moduledoc """
  Bulk-select toolkit for admin tables, **client-side**. The selection
  lives in the browser; the server only learns about it at action time
  (when the user clicks an action button) via the `BulkSelectScope`
  JS hook. This makes per-checkbox toggles feel instant — no LV
  round-trip on every click.

  Three function components compose with `<.table_default>`, plus a
  wrapper element with the hook attached.

    * `<.bulk_select_scope>` — opens an inline-styled wrapper with
      `phx-hook="BulkSelectScope"`. Everything inside (header cell,
      row cells, toolbar buttons) participates in the same selection
      set. Pass `total_count` so the hook knows when "all" is checked.

    * `<.bulk_select_header_cell>` — the header checkbox. Tri-state
      (unchecked / indeterminate / checked) is managed by the hook.

    * `<.bulk_select_cell>` — per-row checkbox bound to a UUID value.

    * `<.bulk_actions_toolbar>` — the toolbar above the table. Buttons
      with `data-bulk-action` dispatch LV events with the selected
      UUIDs in the `{uuids: [...]}` payload.

  ## Example

      <.bulk_select_scope id="projects-bulk" total_count={length(@projects)}>
        <.bulk_actions_toolbar
          on_open_reorder="open_reorder_modal"
          on_clear_selection="clear"
          noun_singular={gettext("project")}
          noun_plural={gettext("projects")}
        />

        <.table_default id="projects-list" size="sm">
          <.table_default_header>
            <.table_default_row>
              <.bulk_select_header_cell
                id="projects-select-all"
                aria_label={gettext("Select all projects")}
              />
              <.table_default_header_cell>Name</.table_default_header_cell>
              ...
            </.table_default_row>
          </.table_default_header>
          <tbody>
            <.table_default_row :for={p <- @projects}>
              <.bulk_select_cell value={p.uuid} />
              <.table_default_cell>{p.name}</.table_default_cell>
              ...
            </.table_default_row>
          </tbody>
        </.table_default>
      </.bulk_select_scope>

  The consumer LV handles `on_open_reorder` (etc.) with a payload of
  `%{"uuids" => uuids}`:

      def handle_event("open_reorder_modal", %{"uuids" => uuids}, socket) do
        {:noreply, assign(socket, show_reorder_modal: true, captured_uuids: uuids)}
      end

  ## Why client-side

  Server-side selection (each click is a `phx-click` round-trip)
  forces a re-render with every toggle, which feels laggy at any
  meaningful network latency. Bulk-select is a high-frequency UI
  interaction where the server only needs to know the selection at
  the moment it acts on it — making the client the natural owner.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  @doc """
  Opens a bulk-select scope. Everything inside this wrapper
  participates in the same selection set.
  """
  attr :id, :string, required: true
  attr :total_count, :integer, required: true
  attr :class, :string, default: ""
  slot :inner_block, required: true

  def bulk_select_scope(assigns) do
    ~H"""
    <div
      id={@id}
      class={@class}
      phx-hook="BulkSelectScope"
      data-bulk-total={@total_count}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Header checkbox cell — drop-in replacement for `<.table_default_header_cell>`
  in the bulk-select column. The `BulkSelectScope` hook drives its
  checked / indeterminate state based on the current selection.
  """
  attr :id, :string, required: true
  attr :aria_label, :string, default: "Toggle select all"
  attr :class, :string, default: "w-8"

  def bulk_select_header_cell(assigns) do
    ~H"""
    <th class={@class}>
      <input
        type="checkbox"
        id={@id}
        class="checkbox checkbox-sm"
        data-bulk-role="select-all"
        aria-label={@aria_label}
      />
    </th>
    """
  end

  @doc """
  Per-row checkbox cell. The `value` is captured into the selection
  set when checked; it's the identifier the server receives in
  `{uuids: [...]}` when an action fires.
  """
  attr :value, :string, required: true
  attr :class, :string, default: "w-8"

  def bulk_select_cell(assigns) do
    ~H"""
    <td class={@class}>
      <input
        type="checkbox"
        class="checkbox checkbox-sm"
        data-bulk-role="row"
        data-uuid={@value}
      />
    </td>
    """
  end

  @doc """
  Floating toolbar above the table. Built-in actions: Reorder, Delete,
  Clear. Each button is opt-in via flags / event-name attrs. Toolbar
  always renders; the count text + button labels + visibility update
  live as the user toggles checkboxes.

  Reorder is mandatory (`on_open_reorder` is required). Delete and
  Clear are optional.
  """
  attr :on_open_reorder, :string,
    required: true,
    doc: "Event pushed when the Reorder button is clicked. Receives `%{\"uuids\" => uuids}`."

  attr :on_bulk_delete, :string,
    default: nil,
    doc: "Event pushed when Delete is clicked. Required if `allow_delete` is true."

  attr :noun_singular, :string, default: "item"
  attr :noun_plural, :string, default: "items"
  attr :allow_delete, :boolean, default: true

  attr :reorder_gate, :atom,
    default: :always,
    values: [:always, :multi],
    doc:
      "When `:always`, the Reorder button is always visible — label is 'Reorder all' when 0–1 rows are selected, 'Reorder N selected' when 2+. (A one-row reorder is a no-op, so we keep the 'Reorder all' label there; the consumer LV normalises 1-uuid scopes to :all when applying.) When `:multi`, hidden unless count > 1 — useful when the surrounding context has no meaningful 'reorder all' interpretation (e.g. the list is currently sorted by name, not the manual position field)."

  slot :leading,
    doc:
      "Content rendered on the left of the toolbar before the action buttons. Common use: tuck a sort selector in here so the toolbar reads as one widget."

  def bulk_actions_toolbar(assigns) do
    assigns =
      assigns
      |> assign(:reorder_empty_label, gettext("Reorder all"))
      |> assign(:reorder_selected_label, gettext_noop("Reorder %{count} selected"))
      |> assign(:delete_label, gettext("Delete"))
      |> assign(:clear_label, gettext("Clear"))

    ~H"""
    <div class="flex flex-wrap items-center gap-3 bg-base-200 rounded-lg px-3 py-2 text-sm">
      {render_slot(@leading)}

      <div class="flex items-center gap-2 ml-auto">
        <button
          type="button"
          class="btn btn-sm btn-ghost"
          data-bulk-action={@on_open_reorder}
          data-bulk-show={if @reorder_gate == :multi, do: "has-multiple"}
          data-bulk-label-empty={if @reorder_gate == :always, do: @reorder_empty_label}
          data-bulk-label-selected={@reorder_selected_label}
        >
          <.icon name="hero-arrows-up-down" class="w-4 h-4" /> {@reorder_empty_label}
        </button>

        <button
          :if={@allow_delete and @on_bulk_delete}
          type="button"
          class="btn btn-sm btn-ghost text-error"
          data-bulk-action={@on_bulk_delete}
          data-bulk-show="has-selection"
        >
          <.icon name="hero-trash" class="w-4 h-4" /> {@delete_label}
        </button>

        <button
          type="button"
          class="btn btn-sm btn-ghost"
          data-bulk-clear="true"
          data-bulk-show="has-selection"
        >
          {@clear_label}
        </button>
      </div>
    </div>
    """
  end
end
