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
  # plain bucket URL — it goes out as a signed URL that makes the bucket
  # say `attachment`, or through the app. Reaching the branch needs a public
  # bucket, which a unit test has not (`Manager.bucket_access/4` is tested
  # on its own in `test/modules/storage/services/`).
  test "a plain bucket URL is handed out only for a type served inline" do
    source = File.read!("lib/phoenix_kit_web/controllers/file_controller.ex")
    [_, branch] = String.split(source, "{:redirect, url} ->", parts: 2)
    [branch, _] = String.split(branch, "{:signed_redirect,", parts: 2)

    assert branch =~ ~s|disposition_for(instance.mime_type) == "inline"|
    assert branch =~ "proxy_remote_file"
  end

  test "a signed redirect is never cached: it would outlive its signature" do
    source = File.read!("lib/phoenix_kit_web/controllers/file_controller.ex")
    [_, branch] = String.split(source, "{:signed_redirect, url} ->", parts: 2)
    [branch, _] = String.split(branch, "{:proxy,", parts: 2)

    assert branch =~ ~s|"cache-control", "private, no-store"|
  end

  describe "content_disposition/2" do
    defp disposition(name, mime \\ "application/zip") do
      FileController.content_disposition(
        %{original_file_name: name},
        %{mime_type: mime, file_name: "ab/cd/abcd_original.zip"}
      )
    end

    test "an ASCII name is quoted as is and repeated as filename*" do
      assert disposition("report 2026.zip") ==
               ~s(attachment; filename="report 2026.zip"; filename*=UTF-8''report%202026.zip)
    end

    test "the disposition follows the type" do
      assert disposition("a.png", "image/png") =~ ~r/^inline; /
    end

    test "a quote, backslash or control character cannot break out of the value" do
      value = disposition(~s(a"b\\c\r\nX-Evil: 1.zip))

      refute value =~ "\r"
      refute value =~ "\n"
      assert value =~ ~s(filename="a_b_c__X-Evil: 1.zip")
    end

    test "a non-ASCII name keeps ASCII in the header and the real name in filename*" do
      value = disposition("фото.zip")

      assert value =~ ~s(filename="____.zip")
      assert value =~ "filename*=UTF-8''%D1%84%D0%BE%D1%82%D0%BE.zip"
      assert value == for(<<c <- value>>, c in 0x20..0x7E, into: "", do: <<c>>)
    end

    test "no original name falls back to the stored key's basename" do
      assert disposition(nil) =~ ~s(filename="abcd_original.zip")
    end
  end
end
