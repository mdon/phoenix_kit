defmodule PhoenixKit.Modules.Storage.ImageEdit do
  @moduledoc """
  The description of an image edit, and the ImageMagick arguments that
  apply it. Pure: no database, no files.

  An edit is a map with string keys (it is stored as JSON on the file) and
  is always applied to the **unedited** original, in this fixed order:

    1. `"rotate"` — 0, 90, 180 or 270 degrees clockwise
    2. `"flip_h"`, `"flip_v"` — mirror left-right / top-bottom
    3. `"straighten"` — a small rotation, −45..45 degrees clockwise, scaled
       about the centre just enough that no blank corner shows
    4. `"redact"` — regions to hide, each `%{"x", "y", "w", "h", "style"}`
    5. `"crop"` — `%{"x", "y", "w", "h"}`
    6. `"brightness"`, `"contrast"` — −100..100

  Regions and the crop are percentages (0..100) of the image as it stands
  after steps 1–3 — what the editor shows. Keeping redaction before the crop
  means changing the crop never moves a redacted area.

  Redaction styles really remove the detail rather than soften it: a
  Gaussian blur of known strength can be partly undone, so `"blur"` first
  shrinks the region to a coarse grid (every cell becomes one averaged
  colour) and only then scales it back up smoothly; `"pixelate"` scales the
  same grid back with hard edges; `"fill"` paints the region black.

  An edit that changes nothing normalises to `nil`.
  """

  @styles ~w(blur pixelate fill)
  @max_regions 50
  @max_straighten 45.0

  # A redacted region is shrunk to at most this many cells along its shorter
  # side, and no cell is smaller than @min_cell pixels: a large region still
  # ends up as a handful of flat colours (a 1600 px face shrunk by a ratio
  # alone would stay a recognisable face), and a region smaller than two
  # cells becomes one flat colour.
  @cells_on_short_side 8
  @min_cell 32

  @typedoc "A normalised edit (string keys, as stored)."
  @type t :: %{optional(String.t()) => term()}

  @doc """
  Validates and normalises an edit from a form or an API caller (atom or
  string keys, numbers or numeric strings). Values are clamped into range
  and anything that changes nothing is dropped; `{:ok, nil}` means "no
  edit".

      iex> PhoenixKit.Modules.Storage.ImageEdit.normalize(%{rotate: -90, flip_h: "true"})
      {:ok, %{"rotate" => 270, "flip_h" => true}}

      iex> PhoenixKit.Modules.Storage.ImageEdit.normalize(%{"crop" => %{"x" => 0, "y" => 0, "w" => 100, "h" => 100}})
      {:ok, nil}
  """
  @spec normalize(map() | nil) :: {:ok, t() | nil} | {:error, atom()}
  def normalize(nil), do: {:ok, nil}

  def normalize(params) when is_map(params) do
    with {:ok, rotate} <- rotate(get(params, "rotate")),
         {:ok, redact} <- regions(get(params, "redact")) do
      edit =
        %{
          "rotate" => rotate,
          "flip_h" => truthy?(get(params, "flip_h")),
          "flip_v" => truthy?(get(params, "flip_v")),
          "straighten" => straighten(get(params, "straighten")),
          "redact" => redact,
          "crop" => crop(get(params, "crop")),
          "brightness" => level(get(params, "brightness")),
          "contrast" => level(get(params, "contrast"))
        }
        |> Map.reject(fn {_key, value} -> value in [nil, 0, false, []] end)

      {:ok, if(edit == %{}, do: nil, else: edit)}
    end
  end

  def normalize(_), do: {:error, :invalid_edit}

  @doc """
  Whether the edit moves pixels (rotate, flip, straighten or crop), as
  opposed to only changing their values (redaction, brightness, contrast).
  Annotations are drawn in the unedited image's pixel space, so a geometric
  edit would misplace them.
  """
  @spec geometric?(t() | nil) :: boolean()
  def geometric?(nil), do: false

  def geometric?(edit) when is_map(edit) do
    Enum.any?(~w(rotate flip_h flip_v straighten crop), &Map.has_key?(edit, &1))
  end

  @doc """
  The size of the frame the percentages refer to — the image after
  rotation (a quarter turn swaps the sides); flipping and straightening
  keep it.

      iex> PhoenixKit.Modules.Storage.ImageEdit.frame_size(%{"rotate" => 90}, {400, 300})
      {300, 400}
  """
  @spec frame_size(t() | nil, {pos_integer(), pos_integer()}) :: {pos_integer(), pos_integer()}
  def frame_size(%{"rotate" => r}, {w, h}) when r in [90, 270], do: {h, w}
  def frame_size(_edit, size), do: size

  @doc """
  The size of the result, for an original of `size` (after auto-orient).

      iex> PhoenixKit.Modules.Storage.ImageEdit.output_size(
      ...>   %{"rotate" => 90, "crop" => %{"x" => 0, "y" => 0, "w" => 50, "h" => 25}},
      ...>   {400, 300}
      ...> )
      {150, 100}
  """
  @spec output_size(t() | nil, {pos_integer(), pos_integer()}) :: {pos_integer(), pos_integer()}
  def output_size(edit, size) do
    frame = frame_size(edit, size)

    case edit do
      %{"crop" => crop} ->
        {_x, _y, w, h} = pixels(crop, frame)
        {w, h}

      _ ->
        frame
    end
  end

  @doc """
  The scale that keeps a `w` x `h` frame fully covered after rotating the
  image by `degrees` about its centre (either direction).

      iex> PhoenixKit.Modules.Storage.ImageEdit.straighten_scale(100, 100, 0)
      1.0
  """
  @spec straighten_scale(number(), number(), number()) :: float()
  def straighten_scale(w, h, degrees) do
    theta = abs(degrees) * :math.pi() / 180
    cos = abs(:math.cos(theta))
    sin = abs(:math.sin(theta))
    max((w * cos + h * sin) / w, (w * sin + h * cos) / h) * 1.0
  end

  @doc """
  ImageMagick (`convert`) arguments that apply `edit` to the first frame of
  `input`, whose size after auto-orient is `size`, and write `output`.
  """
  @spec magick_args(t() | nil, {pos_integer(), pos_integer()}, String.t(), String.t()) ::
          [String.t()]
  def magick_args(edit, size, input, output) do
    edit = edit || %{}
    frame = frame_size(edit, size)

    List.flatten([
      # Settings made inside a redaction's parentheses stay inside them.
      "-respect-parentheses",
      "#{input}[0]",
      ["-auto-orient", "+repage"],
      rotate_args(edit),
      flip_args(edit),
      straighten_args(edit, frame),
      Enum.map(Map.get(edit, "redact", []), &redact_args(&1, frame)),
      crop_args(edit, frame),
      tone_args(edit),
      # EXIF (GPS included), XMP and IPTC are profiles; comments are not.
      ["+profile", "!icc,*", "+set", "comment", "-quality", "92", output]
    ])
  end

  ## Args

  defp rotate_args(%{"rotate" => r}), do: ["-rotate", Integer.to_string(r), "+repage"]
  defp rotate_args(_), do: []

  defp flip_args(edit) do
    [
      if(edit["flip_h"], do: "-flop", else: []),
      if(edit["flip_v"], do: "-flip", else: [])
    ]
  end

  defp straighten_args(%{"straighten" => degrees}, {w, h}) do
    scale = straighten_scale(w, h, degrees)

    [
      "-virtual-pixel",
      "edge",
      "-distort",
      "SRT",
      "#{format_float(scale)},#{format_float(degrees)}",
      "+repage"
    ]
  end

  defp straighten_args(_edit, _frame), do: []

  defp redact_args(region, frame) do
    {x, y, w, h} = pixels(region, frame)

    [
      "(",
      "+clone",
      "-crop",
      "#{w}x#{h}+#{x}+#{y}",
      "+repage",
      style_args(region["style"], w, h),
      ")",
      "-gravity",
      "NorthWest",
      "-geometry",
      "+#{x}+#{y}",
      # Copy, not Over: the patch replaces the region even where it is
      # transparent, instead of letting the original show through.
      "-compose",
      "Copy",
      "-composite",
      "-compose",
      "Over"
    ]
  end

  defp style_args("fill", _w, _h), do: ["-alpha", "off", "-fill", "black", "-colorize", "100"]

  # `-alpha off` first: fully transparent pixels still carry colour, and it
  # must not leak into the averages. Sizes are exact (`!`) so the patch
  # covers the whole region.
  defp style_args(style, w, h) do
    cell = max(@min_cell, ceil(min(w, h) / @cells_on_short_side))
    grid = "#{max(1, div(w, cell))}x#{max(1, div(h, cell))}!"
    back = "#{w}x#{h}!"

    case style do
      "pixelate" ->
        ["-alpha", "off", "-scale", grid, "-scale", back]

      _blur ->
        ["-alpha", "off", "-scale", grid, "-filter", "Triangle", "-resize", back]
    end
  end

  defp crop_args(%{"crop" => crop}, frame) do
    {x, y, w, h} = pixels(crop, frame)
    ["-crop", "#{w}x#{h}+#{x}+#{y}", "+repage"]
  end

  defp crop_args(_edit, _frame), do: []

  defp tone_args(edit) do
    case {Map.get(edit, "brightness", 0), Map.get(edit, "contrast", 0)} do
      {0, 0} -> []
      {b, c} -> ["-brightness-contrast", "#{b}x#{c}"]
    end
  end

  # A percentage rectangle as whole pixels inside the frame, at least 1x1.
  defp pixels(%{"x" => x, "y" => y, "w" => w, "h" => h}, {fw, fh}) do
    px = min(round(x / 100 * fw), fw - 1)
    py = min(round(y / 100 * fh), fh - 1)
    pw = max(1, min(round(w / 100 * fw), fw - px))
    ph = max(1, min(round(h / 100 * fh), fh - py))
    {px, py, pw, ph}
  end

  ## Normalisation

  defp rotate(nil), do: {:ok, 0}

  defp rotate(value) do
    case to_number(value) do
      n when is_number(n) ->
        turns = Integer.mod(round(n), 360)

        if rem(turns, 90) == 0,
          do: {:ok, turns},
          else: {:error, :invalid_rotation}

      _ ->
        {:error, :invalid_rotation}
    end
  end

  defp straighten(value) do
    case to_number(value) do
      n when is_number(n) ->
        degrees =
          n |> max(-@max_straighten) |> min(@max_straighten) |> Kernel.*(1.0) |> Float.round(1)

        if degrees == 0, do: nil, else: degrees

      _ ->
        nil
    end
  end

  defp crop(value) do
    case rect(value, 1.0) do
      %{"x" => x, "y" => y, "w" => w, "h" => h} = rect
      when x > 0 or y > 0 or w < 100 or h < 100 ->
        rect

      _ ->
        nil
    end
  end

  defp regions(nil), do: {:ok, []}

  defp regions(list) when is_list(list) do
    if length(list) > @max_regions do
      {:error, :too_many_regions}
    else
      {:ok,
       Enum.flat_map(list, fn region ->
         case rect(region, 0.5) do
           nil -> []
           rect -> [Map.put(rect, "style", style(get(region, "style")))]
         end
       end)}
    end
  end

  # Forms send lists as maps keyed by position ("0", "1", ...).
  defp regions(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _} -> to_number(key) || 0 end)
    |> Enum.map(&elem(&1, 1))
    |> regions()
  end

  defp regions(_), do: {:error, :invalid_regions}

  defp style(value) when is_atom(value) and not is_nil(value), do: style(Atom.to_string(value))
  defp style(value) when value in @styles, do: value
  defp style(_), do: "blur"

  # A rectangle in percent, clamped inside 0..100, or nil when it is not a
  # rectangle of at least `min` percent on each side.
  defp rect(value, min) when is_map(value) do
    with x when is_number(x) <- to_number(get(value, "x")),
         y when is_number(y) <- to_number(get(value, "y")),
         w when is_number(w) <- to_number(get(value, "w")),
         h when is_number(h) <- to_number(get(value, "h")) do
      x = clamp(x, 0, 100)
      y = clamp(y, 0, 100)
      w = clamp(w, 0, 100 - x)
      h = clamp(h, 0, 100 - y)

      if w >= min and h >= min,
        do: %{"x" => round3(x), "y" => round3(y), "w" => round3(w), "h" => round3(h)},
        else: nil
    else
      _ -> nil
    end
  end

  defp rect(_value, _min), do: nil

  defp level(value) do
    case to_number(value) do
      n when is_number(n) -> n |> round() |> clamp(-100, 100)
      _ -> nil
    end
  end

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> nil
  end

  defp to_number(value) when is_number(value), do: value

  defp to_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_number(_), do: nil

  defp clamp(value, lo, hi), do: value |> max(lo) |> min(hi)

  defp round3(value), do: Float.round(value * 1.0, 3)

  defp format_float(value), do: :erlang.float_to_binary(value * 1.0, decimals: 4)
end
