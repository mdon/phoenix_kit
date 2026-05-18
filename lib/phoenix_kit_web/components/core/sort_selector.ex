defmodule PhoenixKitWeb.Components.Core.SortSelector do
  @moduledoc """
  Sort bar for list LiveViews — a field-picker `<.select>` plus a direction-
  toggle button (chevron up / down). No wrapper chrome so it integrates
  cleanly into a `<.table_default toggleable>` `:toolbar_title` slot.

  ## How events fire

  Race-free by design. Each control sends ONLY the field it controls:

  - Field `<.select>` fires `phx-change` with `params == %{"sort_by" => "..."}`
  - Direction button fires `phx-click` with `params == %{"sort_dir" => "..."}`

  The LV handler derives the missing field from `socket.assigns` instead of
  trusting stale DOM — so clicking the arrow while a change event is mid-
  flight can never clobber the in-flight change.

      def handle_event("sort_form", params, socket) do
        field_str = params["sort_by"] || Atom.to_string(socket.assigns.sort_by)
        dir_str   = params["sort_dir"] || Atom.to_string(socket.assigns.sort_dir)
        # cast / validate, then push_patch with both values
        ...
      end

  ## Loading state

  The button shows a spinner during in-flight clicks via Phoenix's auto-
  applied `.phx-click-loading` class (no consumer code required). When the
  field select fires, the form gets `.phx-change-loading` and the select
  dims via the same mechanism. Both states fade automatically when the LV
  acks the event.

  ## Attributes

  - `sort_by` — Current sort field. Accepts atom or string. Required.
  - `sort_dir` — Current direction (`:asc` | `:desc` | `"asc"` | `"desc"`).
    Anything else falls back to `:asc`. Required.
  - `options` — List of `{field, label}` tuples for the field select.
    `field` may be atom or string; `label` is coerced via `to_string/1`.
    Bad rows (non-tuple) are silently dropped. Empty list renders an
    empty `<select>`. Required.
  - `event` — Phoenix event name fired on both field change and direction
    flip. Default `"sort_form"`.
  - `target` — Optional `phx-target` for LiveComponents.
  - `class` — Extra classes on the inner `<form>` element.

  ## Edge cases handled

  - **Atom-or-string inputs**: `sort_by` and `sort_dir` are normalised
    internally; the consumer doesn't need to convert.
  - **Unknown direction**: any value outside the known set renders as
    `:asc` (conservative — surfaces a stable icon instead of silently
    rendering as descending on bad input).
  - **Bad option shape**: non-tuple rows skipped; atom-or-string labels
    coerced. One bad row doesn't blow up the whole select.
  - **Nil / wrong type `options`**: returns empty list, doesn't crash.

  ## Example

      <.sort_selector
        sort_by={@sort_by}
        sort_dir={@sort_dir}
        options={@sort_options}
      />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]

  attr :sort_by, :any, required: true, doc: "Current sort field (atom or string)"
  attr :sort_dir, :any, required: true, doc: "Current direction (:asc/:desc or 'asc'/'desc')"

  attr :options, :list,
    required: true,
    doc: "List of {field, label} tuples — field may be atom or string"

  attr :event, :string, default: "sort_form"
  attr :target, :any, default: nil
  attr :class, :string, default: nil

  attr :manual_field, :any,
    default: nil,
    doc:
      "Atom or string field key that represents \"manual\" ordering (e.g. `:sort_order`). When `sort_by` matches, the direction toggle is replaced by a static drag-handle hint icon — direction has no meaning for a user-specified order."

  def sort_selector(assigns) do
    sort_by_str = to_field_str(assigns[:sort_by])
    manual_str = to_field_str(assigns[:manual_field])
    manual_active? = manual_str != "" and sort_by_str == manual_str

    assigns =
      assigns
      |> assign(:sort_by_str, sort_by_str)
      |> assign(:sort_dir_norm, normalize_dir(assigns[:sort_dir]))
      |> assign(:normalized_options, normalize_options(assigns[:options]))
      |> assign(:manual_active?, manual_active?)

    ~H"""
    <%!-- Render nothing when there's nothing to sort by. Empty options
         could happen if the consumer accidentally passes `[]` or if a
         normalize step drops every malformed row. Better an absent
         control than a broken empty <select>. --%>
    <%= if @normalized_options == [] do %>
    <% else %>
    <.form
      for={%{}}
      phx-change={@event}
      phx-target={@target}
      class={[
        "flex flex-wrap gap-2 items-center transition-opacity",
        "[&.phx-change-loading]:opacity-70 [&.phx-change-loading]:cursor-wait",
        @class
      ]}
    >
      <%!-- daisyUI `join` fuses the field select and direction toggle into
           one widget: shared borders, no gap, single rounded rectangle. --%>
      <div class="join">
        <%!-- Visual label dropped to match the toolbar siblings' heights;
             accessible name preserved via `aria-label` on the <select> --%>
        <.select
          name="sort_by"
          value={@sort_by_str}
          options={@normalized_options}
          class="select-sm join-item"
          aria-label={gettext("Sort by")}
        />
        <%!-- In manual mode, direction is meaningless — replace the click-
             to-flip arrow with a static drag-handle hint so the join still
             reads as one widget but doesn't pretend to toggle anything. --%>
        <span
          :if={@manual_active?}
          class="btn btn-sm btn-square join-item pointer-events-none text-base-content/60"
          title={gettext("Drag rows to reorder")}
          aria-label={gettext("Drag rows to reorder")}
        >
          <.icon name="hero-bars-3" class="w-4 h-4" />
        </span>
        <button
          :if={!@manual_active?}
          type="button"
          phx-click={@event}
          phx-target={@target}
          phx-value-sort_dir={flip_dir_str(@sort_dir_norm)}
          class="btn btn-sm btn-square join-item [&.phx-click-loading]:pointer-events-none"
          title={direction_title(@sort_dir_norm)}
          aria-label={direction_title(@sort_dir_norm)}
        >
          <%!-- Sort-direction icon (`hero-bars-arrow-*` is the canonical
               "sort asc/desc" pair — bars + directional arrow, visually
               distinct from the <select>'s dropdown chevron next to it).
               Hidden while a click event is in flight. --%>
          <.icon
            name={direction_icon(@sort_dir_norm)}
            class="w-4 h-4 [.phx-click-loading_&]:hidden"
          />
          <%!-- Spinner — hidden by default; revealed while an ancestor
               button carries Phoenix's `.phx-click-loading` class --%>
          <span class="hidden [.phx-click-loading_&]:inline-block loading loading-spinner loading-xs">
          </span>
        </button>
      </div>
    </.form>
    <% end %>
    """
  end

  # ---- normalization helpers ------------------------------------------------

  # Accepts atom or string, returns the string form. Used for the select's
  # `value=` and the arrow's `phx-value-sort_dir=`. We never want to crash
  # here so non-castable values become "" (empty), rendering the select
  # with no option selected.
  defp to_field_str(v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp to_field_str(v) when is_binary(v), do: v
  defp to_field_str(_), do: ""

  # Direction normalisation: returns `:asc` or `:desc`. Anything outside
  # the known set falls back to `:asc` (conservative — surfaces a stable
  # icon instead of silently rendering as descending on bad input).
  defp normalize_dir(:asc), do: :asc
  defp normalize_dir(:desc), do: :desc
  defp normalize_dir("asc"), do: :asc
  defp normalize_dir("desc"), do: :desc
  defp normalize_dir(_), do: :asc

  # String form of the flipped direction — what the arrow click should
  # send to the LV next.
  defp flip_dir_str(:asc), do: "desc"
  defp flip_dir_str(:desc), do: "asc"

  defp direction_icon(:asc), do: "hero-bars-arrow-up"
  defp direction_icon(:desc), do: "hero-bars-arrow-down"

  defp direction_title(:asc), do: gettext("Ascending — click for descending")
  defp direction_title(:desc), do: gettext("Descending — click for ascending")

  # Normalises `{field, label}` tuples to `{label_string, field_string}`
  # (the shape `<.select options=...>` expects). Tolerates atom or string
  # on either side, and silently drops anything that isn't a 2-tuple so
  # one bad row doesn't blow up the whole select.
  defp normalize_options(opts) when is_list(opts) do
    Enum.flat_map(opts, fn
      {field, label} -> [{to_string(label), to_field_str(field)}]
      _ -> []
    end)
  end

  defp normalize_options(_), do: []
end
