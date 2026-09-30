defmodule PhoenixKit.Modules.Storage.ImagePipelineEdgesTest do
  @moduledoc """
  Edges of the image pipeline: a path that names an ImageMagick coder, an
  upper-case extension, an image claim over bytes nothing recognises, and
  the see-through format setting's place in the spec hash. Skipped where
  ImageMagick is not installed.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Dimension, ImageProcessor, VariantGenerator, VariantSets}

  @moduletag :tmp_dir
  @moduletag :integration

  defp imagemagick? do
    match?({_, 0}, System.cmd("identify", ["-version"], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  test "a file whose path reads as a coder (xc:red) is still decoded as the PNG it is",
       %{tmp_dir: dir} do
    if imagemagick?() do
      File.cd!(dir, fn ->
        {_, 0} = System.cmd("convert", ["-size", "20x10", "xc:skyblue", "png:xc:red"])
        assert File.exists?("xc:red")

        # A guard, not a reproduction: ImageMagick prefers an existing file
        # over the coder a name spells, so the old unpinned call read this
        # too. What changed is that the format read is now pinned and
        # limited like every other call; this keeps such a path working.
        assert {:ok, out} =
                 ImageProcessor.sanitize("xc:red", Path.join(dir, "out.png"), format: "png")

        assert {:ok, {20, 10}} = ImageProcessor.extract_dimensions(out)
      end)
    end
  end

  test "a see-through PNG stored under an upper-case .JPG still gets a PNG size", %{tmp_dir: dir} do
    if imagemagick?() do
      path = Path.join(dir, "PHOTO.JPG")
      {_, 0} = System.cmd("convert", ["-size", "10x10", "xc:none", "png:" <> path])

      assert VariantGenerator.output_format(nil, %{file_type: "image", ext: "JPG"}, path) == "png"

      assert VariantGenerator.output_format("JPEG", %{file_type: "image", ext: "png"}, path) ==
               "png"
    end
  end

  test "an image claim over bytes nothing recognises is not stored as an image", %{tmp_dir: dir} do
    path = Path.join(dir, "x.svg")
    File.write!(path, "not an image at all")

    assert Storage.content_mime_type("image/svg+xml", path, "x.svg") == "application/octet-stream"
    assert Storage.content_mime_type("image/x-icon", path, "x.ico") == "application/octet-stream"
  end

  test "the see-through format is part of the spec hash only when it is not the default" do
    d = %Dimension{width: 100, height: 100, quality: 80, maintain_aspect_ratio: true}
    default = VariantSets.spec_hash(d, "jpg")

    try do
      Application.put_env(:phoenix_kit, :variant_alpha_format, "png")
      assert VariantSets.spec_hash(d, "jpg") == default

      Application.put_env(:phoenix_kit, :variant_alpha_format, "webp")
      refute VariantSets.spec_hash(d, "jpg") == default
    after
      Application.delete_env(:phoenix_kit, :variant_alpha_format)
    end
  end
end
