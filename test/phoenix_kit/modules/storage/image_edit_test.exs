defmodule PhoenixKit.Modules.Storage.ImageEditTest do
  @moduledoc """
  `ImageEdit` — what an edit is, and the ImageMagick arguments for it.

  The canonical form matters: it is stored on the file, compared to decide
  whether anything changed, and always applied to the unedited original.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.ImageEdit

  doctest ImageEdit

  describe "normalize/1" do
    test "accepts form input: string numbers, checkbox strings, position-keyed lists" do
      assert {:ok, edit} =
               ImageEdit.normalize(%{
                 "rotate" => "180",
                 "flip_v" => "on",
                 "flip_h" => "false",
                 "straighten" => "-3.25",
                 "brightness" => "12.4",
                 "redact" => %{
                   "1" => %{"x" => "50", "y" => "50", "w" => "10", "h" => "10", "style" => "fill"},
                   "0" => %{"x" => "0", "y" => "0", "w" => "10", "h" => "10"}
                 },
                 "crop" => %{"x" => "10", "y" => "0", "w" => "80", "h" => "100"}
               })

      assert edit == %{
               "rotate" => 180,
               "flip_v" => true,
               "straighten" => -3.3,
               "brightness" => 12,
               "redact" => [
                 %{"x" => +0.0, "y" => +0.0, "w" => 10.0, "h" => 10.0, "style" => "blur"},
                 %{"x" => 50.0, "y" => 50.0, "w" => 10.0, "h" => 10.0, "style" => "fill"}
               ],
               "crop" => %{"x" => 10.0, "y" => +0.0, "w" => 80.0, "h" => 100.0}
             }
    end

    test "clamps into range" do
      assert {:ok, edit} =
               ImageEdit.normalize(%{
                 straighten: 90,
                 contrast: -500,
                 crop: %{x: 90, y: -10, w: 50, h: 200}
               })

      assert edit["straighten"] == 45.0
      assert edit["contrast"] == -100
      assert edit["crop"] == %{"x" => 90.0, "y" => +0.0, "w" => 10.0, "h" => 100.0}
    end

    test "an edit that changes nothing is nil" do
      assert ImageEdit.normalize(%{}) == {:ok, nil}
      assert ImageEdit.normalize(nil) == {:ok, nil}

      assert ImageEdit.normalize(%{rotate: 360, straighten: "0", brightness: 0, flip_h: false}) ==
               {:ok, nil}
    end

    test "degenerate rectangles are dropped, not rendered as a 1px sliver" do
      assert {:ok, nil} =
               ImageEdit.normalize(%{
                 crop: %{x: 10, y: 10, w: 0.2, h: 50},
                 redact: [%{x: 1, y: 1, w: 0.1, h: 5}, %{x: "a", y: 1, w: 5, h: 5}, :nope]
               })
    end

    test "rejects what cannot be an edit" do
      assert ImageEdit.normalize(%{rotate: 45}) == {:error, :invalid_rotation}
      assert ImageEdit.normalize(%{rotate: "left"}) == {:error, :invalid_rotation}
      assert ImageEdit.normalize(%{redact: "everything"}) == {:error, :invalid_regions}

      too_many = for _ <- 1..51, do: %{x: 0, y: 0, w: 5, h: 5}
      assert ImageEdit.normalize(%{redact: too_many}) == {:error, :too_many_regions}
      assert ImageEdit.normalize("rotate") == {:error, :invalid_edit}
    end
  end

  test "geometric?/1 separates moving pixels from changing them" do
    refute ImageEdit.geometric?(nil)
    refute ImageEdit.geometric?(%{"brightness" => 10, "redact" => [%{}]})

    for key <- ~w(rotate flip_h flip_v straighten crop) do
      assert ImageEdit.geometric?(%{key => 1}), key
    end
  end

  describe "straighten_scale/3" do
    test "covers the frame in both directions" do
      # A 2:1 frame turned 45° either way needs the same, larger-than-one scale.
      expected = (2000 * :math.cos(:math.pi() / 4) + 1000 * :math.sin(:math.pi() / 4)) / 1000

      assert_in_delta ImageEdit.straighten_scale(2000, 1000, 45), expected, 1.0e-9
      assert_in_delta ImageEdit.straighten_scale(2000, 1000, -45), expected, 1.0e-9
      assert ImageEdit.straighten_scale(2000, 1000, -15) > 1
    end
  end

  describe "magick_args/4" do
    test "applies the steps in the fixed order, resetting the page after each geometry step" do
      edit = %{
        "rotate" => 90,
        "flip_h" => true,
        "straighten" => 5.0,
        "redact" => [%{"x" => 0.0, "y" => 0.0, "w" => 50.0, "h" => 50.0, "style" => "fill"}],
        "crop" => %{"x" => 25.0, "y" => 25.0, "w" => 50.0, "h" => 50.0},
        "brightness" => 10
      }

      args = ImageEdit.magick_args(edit, {400, 200}, "in.jpg", "out.jpg")

      # The last "-crop" is the crop step; each redaction crops its own clone first.
      order =
        Enum.map(
          ~w(-auto-orient -rotate -flop -distort -composite -crop -brightness-contrast +profile),
          &last_index(args, &1)
        )

      assert order == Enum.sort(order)
      assert Enum.take(args, 2) == ["-respect-parentheses", "in.jpg[0]"]
      assert List.last(args) == "out.jpg"

      # The frame is 200x400 after the quarter turn, so percentages map onto it.
      assert "100x200+0+0" in args
      assert "100x200+50+100" in args
      assert Enum.at(args, index(args, "-rotate") + 2) == "+repage"
      assert Enum.at(args, index(args, "-distort") + 3) == "+repage"
    end

    test "keeps the ICC profile and drops the rest of the metadata" do
      args = ImageEdit.magick_args(nil, {10, 10}, "a.png", "b.png")
      assert ["+profile", "!icc,*"] == Enum.slice(args, index(args, "+profile"), 2)
    end

    test "redaction keeps cells large in absolute pixels" do
      region = fn w, h -> %{"x" => 0.0, "y" => 0.0, "w" => w, "h" => h, "style" => "pixelate"} end

      # 20x20 px: smaller than two 32 px cells, so one flat colour.
      assert "1x1!" in ImageEdit.magick_args(
               %{"redact" => [region.(20.0, 20.0)]},
               {100, 100},
               "i",
               "o"
             )

      # 1600x800 px: at most 8 cells on the short side (100 px each).
      assert "16x8!" in ImageEdit.magick_args(
               %{"redact" => [region.(100.0, 100.0)]},
               {1600, 800},
               "i",
               "o"
             )
    end
  end

  defp index(list, item), do: Enum.find_index(list, &(&1 == item))

  defp last_index(list, item),
    do: length(list) - 1 - Enum.find_index(Enum.reverse(list), &(&1 == item))
end
