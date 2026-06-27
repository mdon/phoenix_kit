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
    then the 300px `small`; skips the blurry 150px thumbnail and never the
    full-res original (which would force a live vector overlay)
  - `:medium` — for gallery/preview: prefers medium/thumbnail variants

  ## Attributes

  - `file` - Media file map with `file_type` and `urls` fields (required)
  - `size` - Thumbnail size preference: `:small` or `:medium` (default: `:small`)

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
    # shows the markup at the right quality; otherwise the 300px `small`. The
    # blurry 150px `thumbnail` is skipped, and the full-res `original` (which
    # would force a live vector overlay) is only the last resort — keeps the
    # page light.
    urls["thumbnail_annotated"] || urls["small"] || urls["medium"] || urls["original"]
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
end
