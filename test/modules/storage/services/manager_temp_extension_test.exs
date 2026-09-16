defmodule PhoenixKit.Modules.Storage.ManagerTempExtensionTest do
  @moduledoc """
  A processing temp copy keeps the stored extension only for media types.
  ICO needs its extension for ImageMagick to decode it at all; `.mvg`,
  `.msl` or `.txt` — coders chosen by extension alone — must not get one,
  since the extension is the uploader's filename.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.Manager

  test "media extensions are kept" do
    for path <- ~w(a/b_original.ico a/b.png a/b.JPG a/b.webp a/b.pdf a/b.mp4 a/b.mp3) do
      assert Manager.temp_extension(path) == Path.extname(path), path
    end
  end

  test "extension-selected ImageMagick coders and unknown extensions are dropped" do
    for path <- ~w(a/b.mvg a/b.msl a/b.txt a/b.ps a/b.eps a/b.png[0] a/b.bin a/b) do
      assert Manager.temp_extension(path) == "", path
    end
  end
end
