defmodule PhoenixKitWeb.Components.MediaCanvasViewer do
  # PhoenixKitComments is an optional sibling package — silence undefined
  # warnings for parent apps that don't install it. The comments_enabled?/0
  # helper guards every actual call at runtime with Code.ensure_loaded?/1.
  @compile {:no_warn_undefined, [PhoenixKitComments, PhoenixKitComments.Web.CommentsComponent]}

  @moduledoc """
  Per-file viewer LiveComponent: `<Fresco.canvas>` + `<Etcher.layer>` for
  images, video / PDF / icon fallback for other types, plus a sidebar
  with filename + Download + metadata + comments thread. Owns the
  annotation lifecycle (composer popover, persistence sync via
  `EtcherAdapter`, the patch-shape / delete-shape JS bridges).

  Shared between `MediaBrowser` (admin file grid → click image → modal)
  and `MediaViewer` (lightbox embedded by `MediaGallery` and other
  consumers). Both parents own their own modal shell + prev/next
  navigation; this component is just the per-file content.

  ## Required assigns

    * `:id` — DOM id, **must include the file uuid** so the parent's
      prev/next navigation remounts the component on file change (and
      Fresco's `phx-update="ignore"` canvas DOM is replaced wholesale
      with the new file's image).
    * `:file` — curated file map (`%{file_uuid, mime_type, urls,
      filename, file_type, size, inserted_at, ...}`). Same shape
      `MediaBrowser`'s `uploaded_files` carries.
    * `:current_user` — logged-in user; nil-tolerant. When nil the
      composer + comments thread don't render (no user to attribute
      a comment to).
    * `:parent_id` — DOM id of the *outer* LiveComponent (the modal
      host). Currently unused by this component, but kept on the
      assigns map so future cross-component send_updates have a
      target without re-plumbing the API.
  """

  use PhoenixKitWeb, :live_component

  require Logger

  alias PhoenixKit.Annotations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Utils.Format

  # ──────────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:viewer_canvas, nil)
     |> assign(:viewer_annotations, [])
     |> assign(:composing_annotation_uuid, nil)}
  end

  @impl true
  def update(%{action: :annotation_composer_posted} = assigns, socket) do
    {:ok, finalize_annotation_compose(socket, assigns[:annotation_uuid], assigns[:title])}
  end

  def update(%{action: :annotation_composer_cancelled} = assigns, socket) do
    {:ok, rollback_annotation_compose(socket, assigns[:annotation_uuid])}
  end

  def update(assigns, socket) do
    file = assigns[:file]

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:file, file)
      |> assign(:current_user, assigns[:current_user])
      |> assign(:parent_id, assigns[:parent_id])
      |> assign(:has_prev, assigns[:has_prev] || false)
      |> assign(:has_next, assigns[:has_next] || false)

    # First mount (or file changed via re-mount): hydrate annotations
    # + canvas. Because the id encodes the file uuid, the parent's
    # prev/next destroys this LC and mounts a fresh one, so this
    # branch effectively only runs at mount time.
    socket =
      if socket.assigns[:viewer_canvas] == nil and is_map(file) do
        annotations = load_annotations_for(file.file_uuid)

        socket
        |> assign(:viewer_annotations, annotations)
        |> assign(:viewer_canvas, build_viewer_canvas(file, annotations))
      else
        socket
      end

    {:ok, socket}
  end

  # ──────────────────────────────────────────────────────────────
  # Etcher events
  # ──────────────────────────────────────────────────────────────

  # Bulk persistence sync. Etcher 0.3 emits this on every shape
  # mutation (create, update, drag, delete, color, undo/redo, …) with
  # the full current annotations list. Diff against our last-known
  # state (`viewer_annotations`) to dispatch row-level
  # create/update/delete via `EtcherAdapter`, then reload from DB to
  # pick up fresh comment metadata and rebuild the canvas blob.
  #
  # Persist failures get logged so a stale CHECK constraint (e.g. a
  # new kind that hasn't migrated yet) doesn't silently drop
  # annotations — without this the only symptom is "tooltip shows the
  # kind name with no title sibling," which leads to long debugging
  # detours.
  @impl true
  def handle_event("etcher:annotations-changed", %{"annotations" => new_annotations}, socket) do
    case socket.assigns[:file] do
      nil -> {:noreply, socket}
      file -> {:noreply, sync_annotations(socket, file, new_annotations)}
    end
  end

  # Fires only on a brand-new user draw (Etcher's `_finalizeShape`).
  # Undo/redo, drags, color picks all bypass this — they go through
  # `annotations-changed` for persistence but don't re-open the
  # composer. Text shapes get Etcher's inline editor and skip the
  # popup. If the composer is already open mid-compose, keep its
  # target — a second quick draw shouldn't ambush an in-flight
  # title/comment.
  def handle_event("etcher:shape-drawn", %{"uuid" => uuid, "kind" => kind}, socket) do
    socket =
      cond do
        kind == "text" ->
          socket

        is_binary(socket.assigns[:composing_annotation_uuid]) ->
          socket

        true ->
          assign(socket, :composing_annotation_uuid, uuid)
      end

    {:noreply, socket}
  end

  # ──────────────────────────────────────────────────────────────
  # Annotation persistence + canvas blob
  # ──────────────────────────────────────────────────────────────

  defp sync_annotations(socket, file, new_annotations) do
    file_uuid = file.file_uuid

    current_by_uuid =
      Map.new(socket.assigns.viewer_annotations, fn a -> {to_string(a.uuid), a} end)

    new_by_uuid = Map.new(new_annotations, fn a -> {a["uuid"], a} end)

    new_in_batch =
      Enum.reject(new_annotations, fn a -> Map.has_key?(current_by_uuid, a["uuid"]) end)

    wrote? =
      Enum.reduce(new_annotations, false, fn a, wrote? ->
        uuid = a["uuid"]
        current = Map.get(current_by_uuid, uuid)

        result =
          cond do
            current && annotation_unchanged?(a, current) ->
              :skip

            current ->
              Storage.EtcherAdapter.update(uuid, a)

            true ->
              attrs =
                a
                |> Map.put("target_type", "file")
                |> Map.put("target_uuid", file_uuid)
                |> creator_attrs(socket)

              Storage.EtcherAdapter.create(attrs)
          end

        case result do
          :skip ->
            wrote?

          {:ok, _} ->
            true

          {:error, reason} ->
            Logger.warning(
              "[MediaCanvasViewer] annotation persist failed kind=#{inspect(a["kind"])} uuid=#{inspect(uuid)}: #{inspect(reason)}"
            )

            wrote?
        end
      end)

    # Deletes — uuids in our state that aren't in Etcher's anymore.
    to_delete =
      Enum.reject(socket.assigns.viewer_annotations, fn a ->
        Map.has_key?(new_by_uuid, to_string(a.uuid))
      end)

    Enum.each(to_delete, fn a ->
      uuid = to_string(a.uuid)

      case Storage.EtcherAdapter.delete(uuid) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[MediaCanvasViewer] annotation delete failed uuid=#{inspect(uuid)}: #{inspect(reason)}"
          )
      end
    end)

    if wrote? or to_delete != [] do
      # A row was created / updated / deleted — reload from DB to pick up
      # fresh comment metadata + cascade changes (deleted-annotation
      # comments cascading out), then rebuild the canvas blob.
      refreshed = load_annotations_for(file_uuid)
      refresh_file_comments(socket)

      socket
      |> assign(:viewer_annotations, refreshed)
      |> assign(:viewer_canvas, build_viewer_canvas(file, refreshed))
      |> push_metadata_patches(file_uuid, new_in_batch, refreshed)
    else
      # Etcher re-broadcast with no net change — skip the reload and
      # canvas rebuild entirely.
      socket
    end
  end

  # Etcher re-broadcasts the *entire* annotation list on every shape
  # mutation, so a file with N annotations would otherwise issue N
  # UPDATEs per interaction. An annotation is worth a DB write only when
  # Etcher-owned mutable state actually moved — geometry, style or kind.
  # (title / metadata are edited through the composer, not via
  # annotations-changed.) Comparing against the last-known struct lets
  # the untouched rows skip their no-op UPDATE.
  defp annotation_unchanged?(wire, current) do
    wire["geometry"] == current.geometry and
      wire["style"] == current.style and
      wire["kind"] == current.kind
  end

  # For every annotation newly created in this batch, push an
  # `etcher:patch-shape` event with the freshly-loaded metadata
  # (comment_count: 0, comment_created_at, etc.). Etcher's
  # `_finalizeShape` creates shapes with no `metadata` field, so the
  # tooltip would fall back to the shape kind ("Rectangle") until the
  # next file open. This patch hydrates the in-DOM shape immediately
  # so the tooltip shows correct content even before the user posts a
  # title/comment via the AnnotationComposer.
  defp push_metadata_patches(socket, _file_uuid, [], _refreshed), do: socket

  defp push_metadata_patches(socket, file_uuid, new_in_batch, refreshed) do
    refreshed_by_uuid =
      Map.new(refreshed, fn a -> {to_string(a.uuid), a} end)

    Enum.reduce(new_in_batch, socket, fn raw, acc ->
      uuid = raw["uuid"]

      case Map.get(refreshed_by_uuid, uuid) do
        nil ->
          acc

        ann ->
          Phoenix.LiveView.push_event(acc, "etcher:patch-shape", %{
            fresco_id: "media-zoom-" <> file_uuid,
            uuid: ann.uuid,
            metadata: ann.metadata
          })
      end
    end)
  end

  # Build the `%Fresco.Canvas{}` struct the viewer renders. Wraps the
  # file's image as a single-image canvas at {0,0}, with the file's
  # annotations stuffed into `extensions.etcher` so Etcher hydrates
  # them via `handle.getExtension("etcher")` on mount. Returns nil
  # when there's no usable image url — gates the `<Fresco.canvas>`
  # render in the heex.
  defp build_viewer_canvas(nil, _annotations), do: nil

  defp build_viewer_canvas(file, annotations) when is_map(file) do
    src = file.urls["original"] || file.urls["large"] || file.urls["medium"]

    if is_binary(src) and src != "" do
      width = Map.get(file, :width) || 1000
      height = Map.get(file, :height) || 1000

      Fresco.Canvas.new(width: width, height: height)
      |> Fresco.Canvas.add_image(%{
        src: src,
        x: 0,
        y: 0,
        width: width,
        natural_width: width,
        natural_height: height
      })
      |> Fresco.Canvas.put_extension("etcher", %{
        "version" => "1",
        "annotations" => Enum.map(annotations, &etcher_annotation_for_wire/1)
      })
    end
  end

  # Map an in-memory annotation (from `load_annotations_for/1`) to
  # the Etcher 0.3 wire shape (string-keyed map with uuid/kind/
  # geometry plus optional style/metadata).
  defp etcher_annotation_for_wire(a) do
    base = %{
      "uuid" => to_string(a.uuid),
      "kind" => a.kind,
      "geometry" => a.geometry
    }

    base =
      case Map.get(a, :style) do
        nil -> base
        style -> Map.put(base, "style", style)
      end

    case Map.get(a, :metadata) do
      nil -> base
      metadata -> Map.put(base, "metadata", metadata)
    end
  end

  defp load_annotations_for(file_uuid) do
    file_uuid
    |> Annotations.list_for_file_with_previews()
    |> Enum.map(fn %{annotation: a, first_comment: fc, comment_count: count} ->
      # `metadata` flows through to Etcher's tooltip. The JS reads
      # `metadata.label` (consumer-set) plus the comment_* fields we
      # populate here for the auto-rendered preview.
      base_meta = a.metadata || %{}

      comment_meta =
        case fc do
          nil ->
            %{"comment_created_at" => format_date(a.inserted_at), "comment_count" => 0}

          %{} = c ->
            %{
              "comment_text" => truncate(c.content, 80),
              "comment_author" => c.author,
              "comment_thumbnail_url" => c.thumbnail_url,
              "comment_has_attachment" => Map.get(c, :has_attachment, false),
              "comment_count" => count,
              "comment_created_at" => format_date(a.inserted_at)
            }
        end

      # Surface the dedicated title column as `metadata.title` so the
      # JS overlay can render it inline. The column is the source of
      # truth; the metadata key is the JS-facing contract.
      title_meta = if a.title, do: %{"title" => a.title}, else: %{}

      %{
        uuid: a.uuid,
        kind: a.kind,
        geometry: a.geometry,
        style: a.style,
        metadata: base_meta |> Map.merge(comment_meta) |> Map.merge(title_meta)
      }
    end)
  end

  defp creator_attrs(attrs, socket) do
    creator_uuid =
      case socket.assigns[:current_user] do
        %{uuid: uuid} when is_binary(uuid) -> uuid
        _ -> nil
      end

    Map.put(attrs, "creator_uuid", creator_uuid)
  end

  # ──────────────────────────────────────────────────────────────
  # Composer Post / Cancel — driven by AnnotationComposer's
  # send_update with `action: :annotation_composer_posted/_cancelled`
  # ──────────────────────────────────────────────────────────────

  # Post path: comment was created, annotation is solidified.
  # Reload annotations so the tooltip's comment_* fields refresh,
  # poke the file's CommentsComponent so the freshly-posted comment
  # appears in the sidebar without a page reload, and push the
  # updated metadata directly to Etcher's in-DOM shape via the
  # patch-shape bridge (Fresco's `phx-update="ignore"` blocks a
  # canvas-extensions rebuild from reaching the client).
  defp finalize_annotation_compose(socket, annotation_uuid, title) do
    file_uuid =
      case socket.assigns[:file] do
        %{file_uuid: uuid} -> uuid
        _ -> nil
      end

    if annotation_uuid do
      title_val =
        case title do
          nil -> nil
          str when is_binary(str) -> if String.trim(str) == "", do: nil, else: str
          _ -> nil
        end

      _ = PhoenixKit.Annotations.update(annotation_uuid, %{title: title_val})
    end

    refresh_file_comments(socket)
    fresh = if file_uuid, do: load_annotations_for(file_uuid), else: []

    socket =
      socket
      |> assign(:composing_annotation_uuid, nil)
      |> assign(:viewer_annotations, fresh)
      |> rebuild_viewer_canvas(fresh)
      |> put_flash(:info, gettext("Annotation saved"))

    case file_uuid && Enum.find(fresh, fn a -> a.uuid == annotation_uuid end) do
      %{} = ann ->
        Phoenix.LiveView.push_event(socket, "etcher:patch-shape", %{
          fresco_id: "media-zoom-" <> file_uuid,
          uuid: ann.uuid,
          metadata: ann.metadata
        })

      _ ->
        socket
    end
  end

  defp rebuild_viewer_canvas(socket, annotations) do
    case socket.assigns[:file] do
      nil -> socket
      file -> assign(socket, :viewer_canvas, build_viewer_canvas(file, annotations))
    end
  end

  # Cancel path: drop the just-drawn shape so the canvas doesn't
  # carry an untitled placeholder. The `etcher:delete-shape` JS
  # bridge calls `layer.deleteShape(uuid)` — that removes the shape
  # from Etcher's local state + DOM, pushes the delete onto Etcher's
  # undo stack (Cmd+Z restores), and fires `annotations-changed`,
  # which sync_annotations picks up to delete the DB row + cascade
  # the comment hard-delete.
  defp rollback_annotation_compose(socket, annotation_uuid) do
    socket = assign(socket, :composing_annotation_uuid, nil)

    case {annotation_uuid, socket.assigns[:file]} do
      {uuid, %{file_uuid: file_uuid}}
      when is_binary(uuid) and is_binary(file_uuid) ->
        Phoenix.LiveView.push_event(socket, "etcher:delete-shape", %{
          fresco_id: "media-zoom-" <> file_uuid,
          uuid: uuid
        })

      _ ->
        socket
    end
  end

  # Poke the file's CommentsComponent to reload after server-side
  # changes the component didn't drive itself (new annotation
  # comment, cascade-deleted annotation comments, etc.). Flipping
  # `loaded?` to false makes its `update/2` rerun `load_comments/1`.
  defp refresh_file_comments(socket) do
    with %{file_uuid: file_uuid} when is_binary(file_uuid) <- socket.assigns[:file],
         true <- Code.ensure_loaded?(PhoenixKitComments.Web.CommentsComponent) do
      Phoenix.LiveView.send_update(PhoenixKitComments.Web.CommentsComponent,
        id: "media-comments-" <> file_uuid,
        loaded?: false
      )
    end

    :ok
  end

  # ──────────────────────────────────────────────────────────────
  # Format helpers (duplicated from MediaBrowser — small and stable;
  # not worth a shared module yet)
  # ──────────────────────────────────────────────────────────────

  # Tooltip date format. The format string is gettext-wrapped so
  # locales can reorder components ("%d %b %Y" in en-GB / fr / de
  # etc.) without code changes. `strftime`'s month + day-name
  # expansion already resolves through `Calendar` translations.
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, gettext("%b %d, %Y"))
  defp format_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, gettext("%b %d, %Y"))
  defp format_date(_), do: nil

  defp truncate(nil, _), do: nil
  defp truncate("", _), do: nil

  defp truncate(text, limit) when is_binary(text) do
    text = String.trim(text)

    if String.length(text) > limit do
      String.slice(text, 0, limit - 1) <> "…"
    else
      text
    end
  end

  defp format_file_size(nil), do: ""
  defp format_file_size(bytes), do: Format.bytes(bytes, base: 1000, decimals: 2)

  defp file_icon("image"), do: "hero-photo"
  defp file_icon("video"), do: "hero-play-circle"
  defp file_icon("pdf"), do: "hero-document-text"
  defp file_icon("document"), do: "hero-document"
  defp file_icon(_), do: "hero-document-arrow-down"

  @dialyzer {:nowarn_function, comments_enabled?: 0}
  defp comments_enabled? do
    Code.ensure_loaded?(PhoenixKitComments) and PhoenixKitComments.enabled?()
  rescue
    _ -> false
  end
end
