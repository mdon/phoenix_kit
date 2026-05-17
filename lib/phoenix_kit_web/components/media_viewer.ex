defmodule PhoenixKitWeb.Components.MediaViewer do
  @moduledoc """
  Standalone image lightbox ("slide box") LiveComponent.

  Renders a modal showing one image from an ordered set, with prev/next
  navigation (chevrons + ←/→ keys), Escape/backdrop close, and a Download link.
  Images render via `<.image_set>` (responsive `<picture>`).

  Reusable on its own or embedded by `MediaGallery`.

  ## Attrs
  - `id` — required
  - `files` — ordered list of file UUIDs (the navigable set)
  - `current` — UUID currently shown (must be in `files`)
  - `variants_map` — optional `%{uuid => variants}`; resolved internally if absent
  - `file_structs` — optional `[%Storage.File{}]`; resolved internally if absent
  - `notify` — optional `{module, id}`; see Close below

  ## Close
  On close, if `notify: {module, id}` is set:
  `send_update(module, id: id, media_viewer_closed: true)`.
  Otherwise: `send(self(), {__MODULE__, id, :closed})`.
  """
  use PhoenixKitWeb, :live_component

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner

  import PhoenixKit.Modules.Shared.Components.ImageSet

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:files, assigns[:files] || [])
      |> assign_new(:current_uuid, fn -> assigns[:current] end)
      |> assign(:notify, assigns[:notify])
      |> assign_new(:variants_map, fn -> assigns[:variants_map] end)
      |> assign_new(:file_structs, fn -> assigns[:file_structs] end)
      |> resolve_data()

    {:ok, socket}
  end

  @impl true
  def handle_event("close_viewer", _params, socket) do
    close(socket)
    {:noreply, socket}
  end

  def handle_event("step_viewer", %{"dir" => "prev"}, socket),
    do: {:noreply, step_viewer(socket, :prev)}

  def handle_event("step_viewer", %{"dir" => "next"}, socket),
    do: {:noreply, step_viewer(socket, :next)}

  def handle_event("viewer_keydown", %{"key" => "Escape"}, socket) do
    close(socket)
    {:noreply, socket}
  end

  def handle_event("viewer_keydown", %{"key" => "ArrowLeft"}, socket),
    do: {:noreply, step_viewer(socket, :prev)}

  def handle_event("viewer_keydown", %{"key" => "ArrowRight"}, socket),
    do: {:noreply, step_viewer(socket, :next)}

  def handle_event("viewer_keydown", _params, socket), do: {:noreply, socket}

  # ── private ──────────────────────────────────────────────────────────

  defp resolve_data(socket) do
    files = socket.assigns.files

    variants_map =
      socket.assigns.variants_map ||
        safe(fn -> Storage.list_image_set_variants_for_files(files) end, %{})

    file_structs =
      socket.assigns.file_structs ||
        safe(fn -> Storage.get_files(files) end, [])

    assign(socket, variants_map: variants_map, file_structs: file_structs)
  end

  defp safe(fun, fallback) do
    fun.()
  rescue
    e in [DBConnection.ConnectionError, Ecto.Query.CastError] ->
      Logger.warning("MediaViewer: could not load data — #{Exception.message(e)}")
      fallback
  end

  defp close(socket) do
    case socket.assigns.notify do
      {module, id} -> send_update(module, id: id, media_viewer_closed: true)
      _ -> send(self(), {__MODULE__, socket.assigns.id, :closed})
    end
  end

  defp step_viewer(socket, direction) do
    current = socket.assigns.current_uuid
    list = socket.assigns.files

    with idx when is_integer(idx) <- Enum.find_index(list, &(&1 == current)),
         next_idx <- if(direction == :prev, do: idx - 1, else: idx + 1),
         true <- next_idx >= 0 and next_idx < length(list),
         uuid when is_binary(uuid) <- Enum.at(list, next_idx) do
      assign(socket, :current_uuid, uuid)
    else
      _ -> socket
    end
  end

  defp download_url_for(uuid, variants) do
    case Enum.find(variants, &(&1.variant_name == "original")) do
      %{url: url} ->
        url

      _ ->
        try do
          URLSigner.signed_url(uuid, "original", locale: :none)
        rescue
          e in [ArgumentError, FunctionClauseError, KeyError] ->
            Logger.warning(
              "MediaViewer: could not sign download URL for #{uuid} — #{Exception.message(e)}"
            )

            nil
        end
    end
  end

  defp file_name_for(files, uuid) do
    case Enum.find(files, &(&1.uuid == uuid)) do
      %{original_file_name: name} when is_binary(name) -> name
      %{file_name: name} when is_binary(name) -> name
      _ -> uuid
    end
  end
end
