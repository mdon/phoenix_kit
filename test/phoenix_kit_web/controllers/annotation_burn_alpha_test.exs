defmodule PhoenixKitWeb.AnnotationBurnAlphaTest do
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.AnnotationBurnController

  test "pictures that can be see-through burn with their transparency kept" do
    for mime <- ~w(image/png image/webp image/gif image/avif) do
      assert AnnotationBurnController.alpha_mime?(mime), mime
    end

    for mime <- ["image/jpeg", "image/heic", "application/pdf", nil] do
      refute AnnotationBurnController.alpha_mime?(mime), inspect(mime)
    end
  end

  test "the stored format follows the file, as a PNG for a see-through picture" do
    src = File.read!("lib/phoenix_kit_web/controllers/annotation_burn_controller.ex")
    assert src =~ ~s(if alpha_mime?(mime), do: {"png", "image/png"}, else: {"jpg", "image/jpeg"})
    assert src =~ "VariantGenerator.store_prepared_variant(file, variant, out, ext, mime,"
  end
end
