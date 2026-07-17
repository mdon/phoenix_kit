defmodule PhoenixKitWeb.Components.Core.MediaThumbnail do
  @moduledoc """
  Provides a component for resolving and rendering media file thumbnail URLs.

  Handles file type detection (image, video, PDF, document) and selects
  the appropriate thumbnail variant from the file's URL map.
  """

  use Phoenix.Component

  @doc """
  Resolves the best thumbnail URL for a media file.

  Size modes:
  - `:small` (default) — tiny cells (list rows, selectors): prefers the baked
    Etcher thumbnail, then the 150px thumbnail
  - `:card` — large grid/stack cards: prefers the baked Etcher thumbnail (400px),
    then the 300px `small`, then `medium`; only after those falls back to the
    light 150px thumbnail, keeping the full-res original (which would force a
    live vector overlay) as the last resort
  - `:medium` — for gallery/preview: prefers medium/thumbnail variants

  ## Attributes

  - `file` - Media file map with `file_type` and `urls` fields (required)
  - `size` - Thumbnail size preference: `:small`, `:card`, or `:medium` (default: `:small`)

  ## Examples

      <.thumbnail_url file={file} :let={url}>
        <img src={url} />
      </.thumbnail_url>

      <.thumbnail_url file={file} size={:medium} :let={url}>
        <img src={url} />
      </.thumbnail_url>
  """
  attr :file, :map, required: true
  attr :size, :atom, default: :small, values: [:small, :card, :medium]
  slot :inner_block, required: true

  def thumbnail_url(assigns) do
    assigns = assign(assigns, :url, resolve_url(assigns.file, assigns.size))

    ~H"""
    {render_slot(@inner_block, @url)}
    """
  end

  @doc """
  Resolves the best thumbnail URL for a media file.

  Returns `nil` when no suitable URL is available.

  ## Examples

      resolve_url(file)           # small thumbnail
      resolve_url(file, :medium)  # medium preview
  """
  @spec resolve_url(map(), :small | :card | :medium) :: String.t() | nil
  def resolve_url(file, size \\ :small)

  def resolve_url(%{file_type: "video", urls: urls}, _size) do
    urls["video_thumbnail"]
  end

  def resolve_url(%{file_type: "image", urls: urls}, :small) do
    # `thumbnail_annotated` (baked Etcher shapes) wins when present, so list rows
    # show the markup; falls back to the plain 150px thumbnail otherwise.
    urls["thumbnail_annotated"] || urls["thumbnail"] || urls["small"] || urls["original"]
  end

  def resolve_url(%{file_type: "image", urls: urls}, :card) do
    # Large grid/stack cards: the baked Etcher thumbnail (400px) when present
    # shows the markup at the right quality; otherwise the 300px `small`, then
    # `medium`. When a file has neither (partial variant generation, a legacy
    # upload, or admin-disabled dimensions) we still prefer the light 150px
    # `thumbnail` over the full-res `original` — loading the original forces a
    # live vector overlay and a heavy payload, so it stays the true last resort.
    # Keeps the page light.
    urls["thumbnail_annotated"] || urls["small"] || urls["medium"] || urls["thumbnail"] ||
      urls["original"]
  end

  def resolve_url(%{file_type: "image", urls: urls}, :medium) do
    urls["medium"] || urls["thumbnail"] || urls["original"]
  end

  def resolve_url(%{urls: urls}, :small) do
    urls["thumbnail"] || urls["small"]
  end

  def resolve_url(%{urls: urls}, :card) do
    urls["small"] || urls["thumbnail"] || urls["medium"]
  end

  def resolve_url(%{urls: urls}, :medium) do
    urls["thumbnail"] || urls["small"] || urls["medium"]
  end

  def resolve_url(_, _), do: nil

  @doc """
  Tailwind class rotating a thumbnail to the image's saved orientation.

  The orientation lives on the file row (`metadata["rotation"]`, written by
  the viewer's `persist_rotation` bridge) and applies to the whole image, so
  every rendering of it — canvas *and* thumbnail — should honor it. Baked
  variants stay unrotated: rendering the saved angle with a CSS transform
  costs nothing, needs no re-encode, and keeps annotations (which live in
  the image's own coordinate space) aligned as they rotate along.

  Sound only for **square** thumbnail boxes, which is every call site today
  (`aspect-square` grid cards, `w-10 h-10` list cells): a 90°/270° rotation
  of a square leaves the same square, and because `object-cover` crops about
  the center — which rotation maps onto itself — cropping-then-rotating shows
  exactly what rotating-then-cropping would. A non-square box would need the
  swapped-dimension math instead.

  Nil-tolerant: files whose maps carry no `:rotation` (gallery / selector
  builds) and unrotated or garbage values return `nil`.

  ## Examples

      <img src={url} class={["w-full h-full object-cover", rotation_class(file)]} />
  """
  @spec rotation_class(map()) :: String.t() | nil
  def rotation_class(file) when is_map(file) do
    case normalize_rotation(Map.get(file, :rotation)) do
      90 -> "rotate-90"
      180 -> "rotate-180"
      270 -> "-rotate-90"
      _ -> nil
    end
  end

  def rotation_class(_), do: nil

  # Mirrors MediaCanvasViewer's own normalization: only the four snapped
  # angles Fresco emits count; anything else (nil, garbage, a legacy string)
  # reads as unrotated.
  defp normalize_rotation(deg) when is_integer(deg), do: Integer.mod(deg, 360)

  defp normalize_rotation(deg) when is_binary(deg) do
    case Integer.parse(deg) do
      {n, _} -> normalize_rotation(n)
      :error -> 0
    end
  end

  defp normalize_rotation(_), do: 0
end
