defmodule PhoenixKit.Modules.Storage.AnimatedRenditionsTest do
  @moduledoc """
  An animated GIF resized with `animated: true` is still an animation: every frame,
  each put on the full canvas before it is resized (a GIF stores the part that changed,
  and resizing that part alone leaves fragments), with its delay. Skipped where
  ImageMagick is not installed.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.{Dimension, ImageProcessor}

  @moduletag :tmp_dir

  unless System.find_executable("convert") && System.find_executable("identify"),
    do: @moduletag(skip: "ImageMagick (convert, identify) is not installed")

  # A 120x60 white canvas on which a 20 px red square moves right in three frames, 100 ms
  # each, then stored the way a GIF is: each frame holds only what changed.
  defp animated_gif(ctx, frames \\ 3) do
    path = Path.join(ctx.tmp_dir, "anim.gif")

    frame_args =
      for i <- 0..(frames - 1) do
        [
          "(",
          "-size",
          "120x60",
          "xc:white",
          "-fill",
          "red",
          "-draw",
          "rectangle #{i * 30},20 #{i * 30 + 19},39",
          "-set",
          "delay",
          "10",
          ")"
        ]
      end

    {_, 0} =
      System.cmd(
        "convert",
        List.flatten(frame_args) ++ ["-loop", "0", "-layers", "optimize", path],
        stderr_to_stdout: true
      )

    path
  end

  defp identify(path, format) do
    {out, 0} = System.cmd("identify", ["-format", format, path], stderr_to_stdout: true)
    out |> String.split("\n", trim: true)
  end

  defp cropped_gif(ctx) do
    path = Path.join(ctx.tmp_dir, "cropped.gif")

    {_, 0} =
      System.cmd(
        "convert",
        ~w[( -size 120x60 xc:none -fill red -draw] ++
          ["rectangle 40,20 59,39", "-set", "delay", "10", ")"] ++
          ~w[( -size 120x60 xc:none -fill red -draw] ++
          ["rectangle 50,20 69,39", "-set", "delay", "10", ")"] ++
          ["-loop", "0", "-layers", "optimize", path],
        stderr_to_stdout: true
      )

    path
  end

  describe "animation_info/1" do
    test "counts the frames and adds up their delays", ctx do
      assert {:ok, %{frames: 3, duration_ms: 300}} =
               ImageProcessor.animation_info(animated_gif(ctx))
    end

    test "a still picture is one frame", ctx do
      still = Path.join(ctx.tmp_dir, "still.png")
      {_, 0} = System.cmd("convert", ["-size", "10x10", "xc:red", still])
      assert {:ok, %{frames: 1}} = ImageProcessor.animation_info(still)
    end

    test "something that is not an image is an error", ctx do
      bad = Path.join(ctx.tmp_dir, "bad.gif")
      File.write!(bad, "not a gif")
      assert {:error, _} = ImageProcessor.animation_info(bad)
    end
  end

  describe "extract_dimensions/1" do
    test "gives the canvas of an optimised animation, not its first frame's crop", ctx do
      path = cropped_gif(ctx)

      # the first frame is stored as just the 20x20 square
      assert ["20x20" <> _ | _] = identify(path, "%wx%h\n")
      assert {:ok, {120, 60}} = ImageProcessor.extract_dimensions(path)
    end

    test "a plain picture is its own size", ctx do
      path = Path.join(ctx.tmp_dir, "plain.png")
      {_, 0} = System.cmd("convert", ["-size", "80x40", "xc:red", path])

      assert {:ok, {80, 40}} = ImageProcessor.extract_dimensions(path)
    end
  end

  describe "resize with animated: true" do
    test "keeps every frame, each on the whole canvas, and the delays", ctx do
      out = Path.join(ctx.tmp_dir, "small.gif")

      assert {:ok, ^out} =
               ImageProcessor.resize(animated_gif(ctx), out, 60, nil,
                 format: "gif",
                 animated: true
               )

      assert identify(out, "%Wx%H %T\n") == ["60x30 10", "60x30 10", "60x30 10"]

      # The red square is where it should be in each frame, not a fragment of the
      # canvas: after coalescing, the red sits at x = 0, 15 and 30 of 60.
      reds =
        for i <- 0..2 do
          {px, 0} =
            System.cmd("convert", [
              out <> "[#{i}]",
              "-coalesce",
              "-format",
              "%[pixel:p{#{i * 15 + 5},15}]",
              "info:"
            ])

          px
        end

      assert Enum.all?(reds, &(&1 =~ "red" or &1 =~ "255,0,0" or &1 =~ "#FF0000"))
    end

    test "never enlarges", ctx do
      out = Path.join(ctx.tmp_dir, "same.gif")

      assert {:ok, ^out} =
               ImageProcessor.resize(animated_gif(ctx), out, 500, nil,
                 format: "gif",
                 animated: true
               )

      assert identify(out, "%Wx%H\n") |> Enum.uniq() == ["120x60"]
    end

    test "fixes the height when asked", ctx do
      out = Path.join(ctx.tmp_dir, "tall.gif")

      assert {:ok, ^out} =
               ImageProcessor.resize(animated_gif(ctx), out, nil, 30,
                 format: "gif",
                 animated: true
               )

      assert identify(out, "%Wx%H\n") |> Enum.uniq() == ["60x30"]
    end

    test "an animation of too many frames is refused", ctx do
      limit = ImageProcessor.animation_limits().frames
      big = Path.join(ctx.tmp_dir, "long.gif")

      {_, 0} =
        System.cmd("convert", [
          "-size",
          "4x4",
          "xc:red",
          "-duplicate",
          to_string(limit),
          "-loop",
          "0",
          big
        ])

      out = Path.join(ctx.tmp_dir, "long_small.gif")

      assert {:error, message} =
               ImageProcessor.resize(big, out, 2, nil, format: "gif", animated: true)

      assert message =~ "animation is too large"

      refute File.exists?(out)
    end

    test "without animated: a still format gets the first frame", ctx do
      out = Path.join(ctx.tmp_dir, "first.png")
      assert {:ok, ^out} = ImageProcessor.resize(animated_gif(ctx), out, 60, nil, format: "png")
      assert identify(out, "%wx%h\n") == ["60x30"]
    end

    test "animation requires opting in even for GIF and WebP output", ctx do
      source = animated_gif(ctx)

      for format <- ~w(gif webp) do
        out = Path.join(ctx.tmp_dir, "first.#{format}")
        assert {:ok, ^out} = ImageProcessor.resize(source, out, 60, nil, format: format)
        assert {:ok, %{frames: 1}} = ImageProcessor.animation_info(out)
      end
    end

    test "still crops select one frame even for GIF and WebP output", ctx do
      source = animated_gif(ctx)

      for format <- ~w(gif webp), mode <- [:center, :focus] do
        out = Path.join(ctx.tmp_dir, "#{mode}.#{format}")

        result =
          case mode do
            :center ->
              ImageProcessor.resize_and_crop_center(source, out, 30, 30, format: format)

            :focus ->
              ImageProcessor.resize_and_crop_focus(source, out, 30, 30, {0.5, 0.5},
                format: format
              )
          end

        assert {:ok, ^out} = result
        assert {:ok, %{frames: 1}} = ImageProcessor.animation_info(out)
      end
    end

    test "a still rendition of a cropped GIF frame keeps the canvas and subject position", ctx do
      out = Path.join(ctx.tmp_dir, "canvas.png")
      assert {:ok, ^out} = ImageProcessor.resize(cropped_gif(ctx), out, 60, nil, format: "png")
      assert identify(out, "%wx%h\n") == ["60x30"]

      {pixel, 0} = System.cmd("convert", [out, "-format", "%[pixel:p{25,15}]", "info:"])
      assert pixel =~ "255,0,0" or pixel =~ "red" or pixel =~ "#FF0000"
    end

    test "still crops use the canvas of a cropped GIF frame", ctx do
      source = cropped_gif(ctx)

      for mode <- [:center, :focus], strip? <- [true, false] do
        out = Path.join(ctx.tmp_dir, "canvas-#{mode}-#{strip?}.png")
        opts = [format: "png", strip_metadata: strip?]

        result =
          case mode do
            :center ->
              ImageProcessor.resize_and_crop_center(source, out, 30, 30, opts)

            :focus ->
              ImageProcessor.resize_and_crop_focus(source, out, 30, 30, {0.5, 0.5}, opts)
          end

        assert {:ok, ^out} = result
        assert identify(out, "%wx%h\n") == ["30x30"]
        {pixel, 0} = System.cmd("convert", [out, "-format", "%[pixel:p{10,15}]", "info:"])
        assert pixel =~ "255,0,0" or pixel =~ "red" or pixel =~ "#FF0000"
      end
    end

    test "WebP animations retain their frames, canvas and duration", ctx do
      source = Path.join(ctx.tmp_dir, "anim.webp")
      {_, 0} = System.cmd("convert", [animated_gif(ctx), "-coalesce", source])
      out = Path.join(ctx.tmp_dir, "small.webp")

      assert {:ok, ^out} =
               ImageProcessor.resize(source, out, 60, nil, format: "webp", animated: true)

      assert {:ok, %{frames: 3, duration_ms: 300}} = ImageProcessor.animation_info(out)
      assert identify(out, "%Wx%H\n") |> Enum.uniq() == ["60x30"]
    end

    test "strips metadata like any other resize", ctx do
      out = Path.join(ctx.tmp_dir, "stripped.gif")

      assert {:ok, ^out} =
               ImageProcessor.resize(animated_gif(ctx), out, 60, nil,
                 format: "gif",
                 animated: true,
                 strip_metadata: true
               )

      assert length(identify(out, "%n\n") |> Enum.uniq()) == 1
      assert identify(out, "%n\n") |> hd() == "3"
    end
  end

  test "a size keeps the animation unless it says otherwise" do
    assert Dimension.keep_animation?(%Dimension{})
    assert Dimension.keep_animation?(Dimension.new([]))
    refute Dimension.keep_animation?(Dimension.new(keep_animation: false))
  end
end
