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

  # Source-order pin: a public bucket answers with its OWN headers, so a
  # type this app would never show in place must not be handed out as a
  # bucket URL — it goes through the app, which says `attachment`.
  # Reaching the branch needs a public bucket, which a unit test has not.
  test "a bucket URL is handed out only for a type served inline" do
    source = File.read!("lib/phoenix_kit_web/controllers/file_controller.ex")
    [_, branch] = String.split(source, "{:redirect, url} ->", parts: 2)
    [branch, _] = String.split(branch, "{:proxy,", parts: 2)

    assert branch =~ ~s|disposition_for(instance.mime_type) == "inline"|
    assert branch =~ "proxy_remote_file"
  end
end
