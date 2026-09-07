defmodule PhoenixKit.Users.AvatarCropStaleTest do
  @moduledoc """
  A crop must never outlive its file.

  The stored crop bakes in the image's aspect ratio, so applied to a
  different image it renders stretched and mis-framed on every surface.
  The invariant is enforced at the one custom-fields merge every write
  goes through — because per-call-site enforcement already failed once:
  the settings page cleared the crop on a new pick while the admin form
  and `update_user_avatar/4` did not.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth

  @crop %{"x" => 0.3, "y" => 0.4, "zoom" => 2.0, "ar" => 1.5}

  defp user_with_cropped_avatar do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "crop-stale-#{System.unique_integer([:positive])}@example.com",
        "password" => "Password123!long"
      })

    {:ok, user} =
      Auth.update_user_fields(user, %{"avatar_file_uuid" => "file-one", "avatar_crop" => @crop})

    user
  end

  test "changing the avatar file drops the old file's crop" do
    user = user_with_cropped_avatar()

    # The admin form and update_user_avatar/4 write exactly this shape:
    # a new file uuid with no opinion about the crop.
    {:ok, updated} = Auth.update_user_fields(user, %{"avatar_file_uuid" => "file-two"})

    assert updated.custom_fields["avatar_file_uuid"] == "file-two"

    assert updated.custom_fields["avatar_crop"] == nil,
           "the old image's geometry must not frame the new image"
  end

  test "a caller that sets the crop alongside the file wins" do
    user = user_with_cropped_avatar()
    new_crop = %{"x" => 0.5, "y" => 0.5, "zoom" => 3.0, "ar" => 0.8}

    {:ok, updated} =
      Auth.update_user_fields(user, %{
        "avatar_file_uuid" => "file-two",
        "avatar_crop" => new_crop
      })

    assert updated.custom_fields["avatar_crop"] == new_crop
  end

  test "re-writing the same file keeps the crop" do
    user = user_with_cropped_avatar()

    {:ok, updated} = Auth.update_user_fields(user, %{"avatar_file_uuid" => "file-one"})

    assert updated.custom_fields["avatar_crop"] == @crop,
           "the crop still describes the file it was made against"
  end

  test "unrelated custom-field writes leave the crop alone" do
    user = user_with_cropped_avatar()

    {:ok, updated} = Auth.update_user_fields(user, %{"preferred_locale" => "et"})

    assert updated.custom_fields["avatar_crop"] == @crop
  end
end
