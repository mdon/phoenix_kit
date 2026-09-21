defmodule PhoenixKit.Test.ExifFixture do
  @moduledoc """
  JPEGs carrying a hand-built EXIF segment, for capture-date tests.

  Needs no exiftool and no image library: ImageMagick draws a plain JPEG with
  no metadata of its own, and an APP1 segment holding a little-endian TIFF
  structure (IFD0 → Exif IFD → the ASCII date tags) is spliced in after the
  SOI marker — the same bytes a camera writes, so `identify` reads them back
  as it would a real photo.
  """

  @tags %{
    date_time_original: 0x9003,
    date_time_digitized: 0x9004,
    offset_time_original: 0x9011,
    offset_time_digitized: 0x9012
  }

  @doc "Whether ImageMagick is installed, which every function here needs."
  @spec available?() :: boolean()
  def available?, do: not is_nil(System.find_executable("convert"))

  @doc """
  Writes a JPEG to `path` carrying `tags` as EXIF ASCII values, e.g.
  `%{date_time_original: "2018:07:31 23:04:05", offset_time_original: "-07:00"}`.
  An empty map writes an Exif IFD with no date in it. Returns `path`.

  Every call draws a random colour, so no two fixtures share bytes: Storage
  deduplicates by checksum, and two identical uploads would quietly become
  one file.
  """
  @spec write_jpeg!(Path.t(), %{atom() => String.t()}) :: Path.t()
  def write_jpeg!(path, tags \\ %{}) do
    colour = "xc:#" <> Base.encode16(:crypto.strong_rand_bytes(3))

    {_, 0} =
      System.cmd("convert", ["-size", "64x48", colour, "-strip", "jpg:" <> path],
        stderr_to_stdout: true
      )

    <<0xFF, 0xD8, rest::binary>> = File.read!(path)
    File.write!(path, [<<0xFF, 0xD8>>, app1(tags), rest])
    path
  end

  defp app1(tags) do
    entries =
      tags
      |> Enum.map(fn {name, value} -> {Map.fetch!(@tags, name), value <> <<0>>} end)
      |> Enum.sort()

    ifd0_offset = 8
    exif_offset = ifd0_offset + 2 + 12 + 4
    data_offset = exif_offset + 2 + 12 * length(entries) + 4

    {directory, blobs, _cursor} =
      Enum.reduce(entries, {[], [], data_offset}, fn {tag, raw}, {dir, blobs, cursor} ->
        count = byte_size(raw)
        head = <<tag::little-16, 2::little-16, count::little-32>>

        # A value of 4 bytes or fewer sits in the entry itself; a longer one
        # is stored after the directory and the entry holds its offset.
        if count <= 4 do
          {[dir, head, raw, :binary.copy(<<0>>, 4 - count)], blobs, cursor}
        else
          {[dir, head, <<cursor::little-32>>], [blobs, raw], cursor + count}
        end
      end)

    tiff =
      IO.iodata_to_binary([
        "II",
        <<42::little-16, ifd0_offset::little-32>>,
        # IFD0: one entry, the pointer to the Exif IFD; no next IFD.
        <<1::little-16, 0x8769::little-16, 4::little-16, 1::little-32, exif_offset::little-32>>,
        <<0::little-32>>,
        # The Exif IFD: the date tags; no next IFD.
        <<length(entries)::little-16>>,
        directory,
        <<0::little-32>>,
        blobs
      ])

    payload = "Exif" <> <<0, 0>> <> tiff
    <<0xFF, 0xE1, byte_size(payload) + 2::big-16>> <> payload
  end
end
