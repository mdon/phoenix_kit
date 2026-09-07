defmodule PhoenixKit.Users.AvatarCrop do
  @moduledoc """
  Non-destructive avatar cropping, Apple Photos style.

  A crop is data, never pixels: `custom_fields["avatar_crop"]` holds a focal
  point, a zoom, and the image's aspect ratio, while the original file — and
  every generated variant of it — stays exactly as uploaded. Adjusting the
  crop rewrites four numbers; resetting it drops the key; nothing is ever
  re-encoded, so there is no quality loss and no way to crop yourself into a
  corner.

  Rendering applies the stored geometry as an inline style on the `<img>`
  inside the avatar's (square, overflow-hidden) frame. Because the storage
  module's image variants are aspect-preserving scales of the original, the
  same normalized numbers are valid against any of them — a page full of
  avatars keeps loading the small variants it always loaded, and the crop
  costs a few floats that were already in the user record. No extra request,
  no imaging job, no per-crop file.

  ## The stored map

      %{"x" => 0.5, "y" => 0.35, "zoom" => 2.0, "ar" => 1.5}

  - `x`, `y` — the focal point (what the person centered), as fractions of
    the image's width and height. `0.5/0.5` is the image center.
  - `zoom` — magnification relative to the cover fit. `1.0` shows exactly
    what `object-fit: cover` would show; the ceiling is #{inspect(8.0)}.
  - `ar` — the image's width/height ratio, captured when the crop was made
    so rendering never needs to look dimensions up (avatars appear dozens to
    a page; a per-avatar dimension query would be the N+1 this design
    exists to avoid).

  ## Geometry

  Inside a square frame taken as 100%: the cover fit makes the image's short
  side match the frame, so a landscape image is `100·zoom` tall and
  `100·zoom·ar` wide (portrait mirrored). The image is then offset so the
  focal point sits at the frame's center, clamped so the frame never shows
  past an edge — the same clamp the editor applies, so what was saved is
  what renders.
  """

  @min_zoom 1.0
  @max_zoom 8.0
  @min_ar 0.05
  @max_ar 20.0

  # The storage module's seeded image dimensions, widest edge each, in
  # ascending order. A missing variant is served as the original while it
  # generates, so an entry here never 404s.
  @variant_ladder [{"small", 300}, {"medium", 800}, {"large", 1920}]

  @doc """
  The user's stored crop, or nil when there is none (or it is invalid).
  """
  def from_user(%{custom_fields: %{"avatar_crop" => crop}}), do: normalize(crop)
  def from_user(_user), do: nil

  @doc """
  Clamp raw crop params into a storable map, or nil if they do not describe
  a crop at all.

  Accepts string or atom keys and numbers or numeric strings — the values
  arrive from a JS hook. Out-of-range values are clamped rather than
  refused: a drag that overshoots an edge is intent to reach the edge.
  """
  def normalize(%{} = params) do
    with {:ok, x} <- number(params, [:x, "x"]),
         {:ok, y} <- number(params, [:y, "y"]),
         {:ok, zoom} <- number(params, [:zoom, "zoom"]),
         {:ok, ar} <- number(params, [:ar, "ar"]) do
      %{
        "x" => clamp(x, 0.0, 1.0),
        "y" => clamp(y, 0.0, 1.0),
        "zoom" => clamp(zoom, @min_zoom, @max_zoom),
        "ar" => clamp(ar, @min_ar, @max_ar)
      }
    else
      _ -> nil
    end
  end

  def normalize(_), do: nil

  @doc """
  The image's placement inside its square frame, as percentages of the
  frame: `%{width:, height:, left:, top:}`.

  Mirrored by `avatarCropLayout` in `priv/static/assets/phoenix_kit.js` —
  the editor previews with the same math that later renders, so the saved
  crop cannot drift from the preview. Change one, change both.
  """
  def layout(%{"zoom" => zoom, "ar" => ar, "x" => x, "y" => y}) do
    {width, height} =
      if ar >= 1.0 do
        {100.0 * zoom * ar, 100.0 * zoom}
      else
        {100.0 * zoom, 100.0 * zoom / ar}
      end

    %{
      width: width,
      height: height,
      left: clamp(50.0 - x * width, 100.0 - width, 0.0),
      top: clamp(50.0 - y * height, 100.0 - height, 0.0)
    }
  end

  @doc """
  The inline style that seats a cropped image in its frame.

  The frame supplies `position: relative; overflow: hidden` (the avatar
  component already has both); `max-width: none` undoes Tailwind's global
  `img { max-width: 100% }`, without which every percentage below is
  re-clamped and the crop silently collapses to a stretch.
  """
  def img_style(crop) do
    l = layout(crop)

    "position:absolute;max-width:none;" <>
      "width:#{fmt(l.width)}%;height:#{fmt(l.height)}%;" <>
      "left:#{fmt(l.left)}%;top:#{fmt(l.top)}%;"
  end

  @doc """
  The cheapest stored variant that still renders sharply: a zoomed crop
  shows `1/zoom` of the source, so a box of `box_px` CSS pixels needs
  `box_px · 2 (retina) · zoom` source pixels along the frame edge.

  Without a crop, zoom is 1.0 and this degrades to plain size-based
  selection. Falls through to `"original"` when even the large variant
  would be soft.
  """
  def variant_for(box_px, zoom \\ 1.0) do
    needed = box_px * 2 * max(zoom, 1.0)

    Enum.find_value(@variant_ladder, "original", fn {name, edge} ->
      if edge >= needed, do: name
    end)
  end

  @doc "The zoom ceiling, shared with the editor UI."
  def max_zoom, do: @max_zoom

  defp number(params, keys) do
    case Enum.find_value(keys, fn k -> Map.get(params, k) end) do
      value when is_number(value) ->
        {:ok, value / 1}

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> {:ok, parsed}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  # Two decimals is sub-pixel at any avatar size and keeps the style strings
  # (one per avatar on a busy page) short.
  defp fmt(value), do: :erlang.float_to_binary(value / 1, decimals: 2)
end
