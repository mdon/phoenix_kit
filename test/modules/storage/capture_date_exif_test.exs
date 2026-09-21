defmodule PhoenixKit.Modules.Storage.CaptureDateExifTest do
  @moduledoc """
  `CaptureDate` against real JPEG bytes: ImageMagick reads the EXIF segment
  `PhoenixKit.Test.ExifFixture` writes, the way it reads a camera's. Skipped
  where ImageMagick is not installed.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.CaptureDate
  alias PhoenixKit.Test.ExifFixture

  unless ExifFixture.available?() and System.find_executable("identify"),
    do: @moduletag(:skip)

  setup do
    path =
      Path.join(System.tmp_dir!(), "pk_capture_date_#{System.unique_integer([:positive])}.jpg")

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  defp file(name \\ "holiday.jpg"),
    do: %{file_type: "image", original_file_name: name, inserted_at: ~U[2026-09-21 10:00:00Z]}

  test "reads DateTimeOriginal and its offset from the bytes", %{path: path} do
    ExifFixture.write_jpeg!(path, %{
      date_time_original: "2018:07:31 23:04:05",
      offset_time_original: "-07:00"
    })

    assert CaptureDate.resolve(path, file()) == %{
             taken_at: ~U[2018-08-01 06:04:05Z],
             taken_on: ~D[2018-07-31],
             taken_at_offset: -25_200,
             taken_at_source: "exif"
           }
  end

  test "a tag the file lacks is not an error", %{path: path} do
    # ImageMagick 7 warns on stderr for each named tag a file lacks, which is
    # why CaptureDate asks for %[EXIF:*] instead of naming them.
    ExifFixture.write_jpeg!(path, %{date_time_digitized: "2019:01:02 03:04:05"})

    assert %{taken_at_source: "exif", taken_on: ~D[2019-01-02], taken_at_offset: nil} =
             CaptureDate.resolve(path, file())
  end

  test "EXIF without a date falls back to the file name, then the upload time", %{path: path} do
    ExifFixture.write_jpeg!(path)

    assert %{taken_at_source: "filename", taken_on: ~D[2018-07-01]} =
             CaptureDate.resolve(path, file("IMG_20180701_120000.jpg"))

    assert %{taken_at_source: "inserted_at", taken_on: ~D[2026-09-21]} =
             CaptureDate.resolve(path, file())
  end

  test "a zeroed DateTimeOriginal is not a date", %{path: path} do
    ExifFixture.write_jpeg!(path, %{date_time_original: "0000:00:00 00:00:00"})
    assert %{taken_at_source: "inserted_at"} = CaptureDate.resolve(path, file())
  end

  test "bytes that are not an image read as no EXIF", %{path: path} do
    File.write!(path, "not an image")
    assert CaptureDate.read_exif(path) == %{}
  end
end
