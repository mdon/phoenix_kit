defmodule PhoenixKitWeb.AttachmentsHelpersTest do
  @moduledoc """
  The files grid's rules and messages, shared by every module's file form.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Attachments

  defp file(uuid), do: %{uuid: uuid}

  describe "with_featured/2" do
    test "a featured image outside the folder is shown first" do
      assert Attachments.with_featured([file("a"), file("b")], file("f")) ==
               [file("f"), file("a"), file("b")]
    end

    test "a featured image already in the folder is not shown twice" do
      assert Attachments.with_featured([file("a"), file("f")], file("f")) ==
               [file("a"), file("f")]
    end

    test "no featured image changes nothing" do
      assert Attachments.with_featured([file("a")], nil) == [file("a")]
    end
  end

  describe "apply_order/2" do
    test "ordered files first, the rest after in their own order" do
      files = [file("new1"), file("b"), file("new2"), file("a")]

      assert Attachments.apply_order(files, ["a", "gone", "b"]) ==
               [file("a"), file("b"), file("new1"), file("new2")]
    end

    test "an empty or missing order changes nothing" do
      files = [file("b"), file("a")]
      assert Attachments.apply_order(files, []) == files
      assert Attachments.apply_order(files, nil) == files
    end
  end

  describe "messages" do
    test "LiveView's upload errors read as sentences" do
      assert Attachments.error_message(:too_large) == "File is too large."
      assert Attachments.error_message(:not_accepted) == "File type not accepted."
      assert Attachments.error_message(:too_many_files) == "Too many files."
    end

    test "an unknown error names its shape, never its data" do
      message = Attachments.error_message({:storage, "secret-key s3://bucket/object"})
      assert message =~ "Upload error"
      refute message =~ "secret"
    end

    test "a failed upload is named by its base name" do
      assert Attachments.failed_message("../x/plan.pdf", :boom) == "Upload failed for plan.pdf."
    end

    test "a duplicate names the file it matched" do
      assert Attachments.duplicate_notice("copy.pdf", %{original_file_name: "plan.pdf"}) ==
               "copy.pdf is identical to plan.pdf, which is already attached — nothing was added."

      assert Attachments.duplicate_notice("copy.pdf", %{}) =~ "copy.pdf is identical to copy.pdf"
    end
  end
end
