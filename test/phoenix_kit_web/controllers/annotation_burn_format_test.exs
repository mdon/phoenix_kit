defmodule PhoenixKitWeb.AnnotationBurnFormatTest do
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.AnnotationBurnController, as: Burn

  test "a burn is kept by what the stored file is" do
    assert Burn.burn_format_for("image/gif") == "gif"

    for mime <- ~w(image/png image/webp image/avif) do
      assert Burn.burn_format_for(mime) == "png", mime
    end

    for mime <- ["image/jpeg", "image/heic", nil] do
      assert Burn.burn_format_for(mime) == "webp", inspect(mime)
    end
  end

  test "a WebP upload is accepted by its magic" do
    assert Burn.image_magic?("RIFF" <> <<0, 0, 0, 0>> <> "WEBPVP8 ")
    refute Burn.image_magic?("RIFF" <> <<0, 0, 0, 0>> <> "AVI LIST")
  end

  test "an animated burn's layout is read whole, and scaled to the overlay it became" do
    params = %{
      "canvas_w" => "800",
      "canvas_h" => "600",
      "picture_x" => "100.5",
      "picture_y" => "50",
      "picture_w" => "400",
      "picture_h" => "300"
    }

    assert {:ok, layout} = Burn.layout_from_params(params)

    assert Burn.scale_layout(layout, 400, 300) == %{
             canvas_w: 400,
             canvas_h: 300,
             x: 50,
             y: 25,
             w: 200,
             h: 150
           }

    assert Burn.layout_from_params(Map.delete(params, "picture_w")) == :error
    assert Burn.layout_from_params(Map.put(params, "canvas_w", "1e9")) == :error
    assert Burn.layout_from_params(Map.put(params, "picture_h", "abc")) == :error
    assert Burn.layout_from_params(Map.put(params, "picture_x", "abc")) == :error
    assert Burn.layout_from_params(Map.delete(params, "picture_y")) == :error
  end

  test "the fingerprint is written before the file's change is announced" do
    src = File.read!("lib/phoenix_kit_web/controllers/annotation_burn_controller.ex")

    assert src =~
             ~r/remember_fingerprint\(file, params\["fingerprint"\]\)\s+Storage\.broadcast_file_thumbnail_updated\(file\.uuid\)/,
           "a refresh on the broadcast must read the new fingerprint"

    assert length(Regex.scan(~r/broadcast_file_thumbnail_updated/, src)) == 1
  end
end
