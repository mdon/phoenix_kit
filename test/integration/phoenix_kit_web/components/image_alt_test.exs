defmodule PhoenixKitWeb.Components.ImageAltTest do
  @moduledoc """
  The shared `Image` and `ImageSet` components: an image rendered from a
  Storage file with no `alt` written on it gets the file's own alt text.
  """
  use PhoenixKit.DataCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Shared.Components.Image
  alias PhoenixKit.Modules.Shared.Components.ImageSet
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth

  setup do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Auth.register_user(%{email: "alt_#{n}@example.com", password: "ValidPassword123!"})

    file =
      Repo.insert!(%Storage.File{
        original_file_name: "IMG_#{n}.jpg",
        file_name: "img_#{n}.jpg",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        file_checksum: "sha256:alt-#{n}",
        user_file_checksum: "user-sha256:alt-#{n}",
        size: 1024,
        status: "active",
        user_uuid: user.uuid
      })

    {:ok, file} = Storage.update_file_details(file, %{"alt" => "Boats in a harbour"})
    %{image: file}
  end

  describe "ImageSet" do
    test "no alt: the file's own", %{image: file} do
      assigns = %{uuid: file.uuid}
      html = rendered_to_string(~H"<ImageSet.image_set file_uuid={@uuid} />")

      assert html =~ ~s(alt="Boats in a harbour")
    end

    test "an alt the caller wrote wins, and an empty one stays empty (decorative)", %{image: file} do
      assigns = %{uuid: file.uuid}

      assert rendered_to_string(~H(<ImageSet.image_set file_uuid={@uuid} alt="Mine" />)) =~
               ~s(alt="Mine")

      assert rendered_to_string(~H(<ImageSet.image_set file_uuid={@uuid} alt="" />)) =~ ~s(alt="")
    end

    test "pre-loaded variants: nothing is looked up", %{image: file} do
      assigns = %{uuid: file.uuid}
      html = rendered_to_string(~H"<ImageSet.image_set file_uuid={@uuid} variants={[]} />")

      refute html =~ "Boats"
    end
  end

  describe "Image" do
    test "a direct src has no file to ask" do
      assigns = %{attrs: %{"src" => "/logo.png"}}

      assert rendered_to_string(~H"<Image.render attributes={@attrs} />") =~ ~s(alt="")
    end

    test "an alt the author wrote wins over the file's", %{image: file} do
      assigns = %{attrs: %{"src" => "/x.png", "file_uuid" => file.uuid, "alt" => "Mine"}}

      assert rendered_to_string(~H"<Image.render attributes={@attrs} />") =~ ~s(alt="Mine")
    end
  end
end
