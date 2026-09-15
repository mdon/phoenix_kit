defmodule PhoenixKitWeb.Helpers.MediaSelectorHelperTest do
  @moduledoc """
  Unit tests for `MediaSelectorHelper.media_selector_url/2`'s `:scope_folder`
  option. Media hierarchy phase 2, plan 8, task 2.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Helpers.MediaSelectorHelper

  describe "media_selector_url/2 scope_folder" do
    test "a valid uuid is appended to the URL" do
      uuid = Ecto.UUID.generate()

      url = MediaSelectorHelper.media_selector_url("/admin/x", scope_folder: uuid)

      assert url =~ "scope_folder=#{uuid}"
    end

    test "a non-uuid value is ignored" do
      url = MediaSelectorHelper.media_selector_url("/admin/x", scope_folder: "not-a-uuid")

      refute url =~ "scope_folder"
    end

    test "no scope_folder option: the param is absent" do
      url = MediaSelectorHelper.media_selector_url("/admin/x")

      refute url =~ "scope_folder"
    end

    test "other options are unaffected" do
      uuid = Ecto.UUID.generate()

      url =
        MediaSelectorHelper.media_selector_url("/admin/x",
          mode: :multiple,
          filter: :image,
          selected: ["a", "b"],
          scope_folder: uuid
        )

      assert url =~ "mode=multiple"
      assert url =~ "filter=image"
      assert url =~ "selected=a%2Cb"
      assert url =~ "scope_folder=#{uuid}"
    end
  end
end
