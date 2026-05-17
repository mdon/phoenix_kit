defmodule PhoenixKitWeb.Components.MediaGallery do
  @moduledoc """
  A general-purpose LiveComponent for selecting, ordering, previewing and removing
  a set of images.

  Generalizes the gallery + picker pattern so any PhoenixKit consumer can embed it
  instead of re-implementing the plumbing. The component manages an ordered list of
  file UUIDs and reports changes to the parent LiveView.

  ## Usage

      <.live_component
        module={PhoenixKitWeb.Components.MediaGallery}
        id="my-gallery"
        selected={@image_uuids}
        phoenix_kit_current_user={@current_user}
      />

      # Receive changes in parent LiveView
      def handle_info({PhoenixKitWeb.Components.MediaGallery, "my-gallery", {:changed, uuids}}, socket) do
        {:noreply, assign(socket, :image_uuids, uuids)}
      end

  ## Attrs

  - `id` — required; used for element IDs and change notifications
  - `title` — optional heading above the gallery
  - `selected` — ordered list of file UUIDs (current selection); default `[]`
  - `mode` — `:single` or `:multiple` (default `:multiple`)
  - `scope_folder_id` — folder scope passed to the picker
  - `phoenix_kit_current_user` — required for upload in the picker
  - `readonly` — when `true`, hides the pick button, remove buttons, and DnD;
    preview (lightbox) still works; default `false`

  ## Change notifications

  After any change (pick / remove / reorder), the component sends:

      {PhoenixKitWeb.Components.MediaGallery, id, {:changed, ordered_uuids}}

  to the parent LiveView via `send/2`.

  ## SortableGrid hook contract

  Reorder events are emitted by the `SortableGrid` JS hook as
  `"reorder_images:{id}"` with payload `%{"ids" => ordered_uuid_list}`.
  The hook emits `"ids"` (not `"ordered_ids"`).
  """
  use PhoenixKitWeb, :live_component

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitWeb.Live.Components.MediaSelectorModal

  import PhoenixKit.Modules.Shared.Components.ImageSet

  @impl true
  def update(%{media_viewer_closed: true}, socket) do
    {:ok, assign(socket, :preview_uuid, nil)}
  end

  def update(%{media_selector_closed: true}, socket) do
    {:ok, assign(socket, :show_picker, false)}
  end

  def update(%{media_selected: uuids} = _assigns, socket) do
    uuids = uuids || []
    # Guard: if component hasn't been fully initialised yet these are nil-safe defaults.
    current = socket.assigns[:selected] || []
    mode = socket.assigns[:mode] || :multiple
    new_selected = apply_selection(current, uuids, mode)

    socket =
      socket
      |> assign_new(:show_picker, fn -> false end)
      |> assign(:selected, new_selected)
      |> load_files()
      |> assign(:show_picker, false)

    notify_parent(socket)
    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:selected, fn -> [] end)
      |> assign_new(:mode, fn -> :multiple end)
      |> assign_new(:scope_folder_id, fn -> nil end)
      |> assign_new(:phoenix_kit_current_user, fn -> nil end)
      |> assign_new(:readonly, fn -> false end)
      |> assign_new(:title, fn -> nil end)
      |> assign_new(:show_picker, fn -> false end)
      |> assign_new(:preview_uuid, fn -> nil end)
      |> assign_new(:files, fn -> [] end)
      |> assign_new(:variants_map, fn -> %{} end)
      |> load_files()

    {:ok, socket}
  end

  @impl true
  def handle_event("open_picker", _params, socket) do
    {:noreply, assign(socket, :show_picker, true)}
  end

  def handle_event("remove_image", %{"uuid" => uuid}, socket) do
    new_selected = Enum.reject(socket.assigns.selected, &(&1 == uuid))
    socket = socket |> assign(:selected, new_selected) |> load_files()
    notify_parent(socket)
    {:noreply, socket}
  end

  def handle_event("preview_image", %{"uuid" => uuid}, socket) do
    {:noreply, assign(socket, :preview_uuid, uuid)}
  end

  # Reorder event from SortableGrid hook: "reorder_images:{id}" -> ordered ids
  def handle_event("reorder_images:" <> _rest, %{"ids" => ids}, socket) do
    # Re-order `selected` to match the IDs from the SortableGrid hook.
    current = socket.assigns.selected
    new_selected = Enum.filter(ids, &(&1 in current))
    # Append any that weren't in the ids list (shouldn't happen, but guard it)
    leftovers = Enum.reject(current, &(&1 in ids))
    new_selected = new_selected ++ leftovers

    socket = socket |> assign(:selected, new_selected) |> load_files()
    notify_parent(socket)
    {:noreply, socket}
  end

  # ── Private helpers ────────────────────────────────────────────────────

  defp load_files(socket) do
    selected = socket.assigns.selected

    # Skip the DB round-trip when the selection list hasn't changed.
    if selected == socket.assigns[:selected_loaded] do
      socket
    else
      do_load_files(socket, selected)
    end
  end

  defp do_load_files(socket, []) do
    assign(socket, files: [], variants_map: %{}, selected_loaded: [])
  end

  defp do_load_files(socket, selected) do
    files = Storage.get_files(selected)
    variants_map = Storage.list_image_set_variants_for_files(selected)
    assign(socket, files: files, variants_map: variants_map, selected_loaded: selected)
  rescue
    e in [DBConnection.ConnectionError, Ecto.Query.CastError] ->
      Logger.warning("MediaGallery: could not load files — #{Exception.message(e)}")
      assign(socket, files: [], variants_map: %{}, selected_loaded: nil)
  end

  defp apply_selection(_current, uuids, :single) do
    case uuids do
      [uuid | _] -> [uuid]
      [] -> []
    end
  end

  defp apply_selection(_current, uuids, _multiple), do: uuids

  defp notify_parent(socket) do
    parent = self()
    id = socket.assigns.id
    selected = socket.assigns.selected
    send(parent, {PhoenixKitWeb.Components.MediaGallery, id, {:changed, selected}})
  end
end
