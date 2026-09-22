defmodule PhoenixKitWeb.FileDispositionTest do
  @moduledoc """
  A stored file's type is the uploader's claim and is served from the app's
  own origin: only a type a browser cannot run is shown in place.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.FileController

  test "images, PDFs, plain text, video and audio show in place" do
    for type <-
          ~w(image/png image/JPEG image/webp application/pdf text/plain video/mp4 audio/mpeg) do
      assert FileController.disposition_for(type) == "inline", type
    end
  end

  test "anything a browser could run downloads instead" do
    for type <-
          ~w(text/html application/xhtml+xml image/svg+xml text/xml application/javascript text/css) ++
            [nil, "", "application/octet-stream"] do
      assert FileController.disposition_for(type) == "attachment", inspect(type)
    end
  end
end
