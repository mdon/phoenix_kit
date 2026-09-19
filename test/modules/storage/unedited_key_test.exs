defmodule PhoenixKit.Modules.Storage.UneditedKeyTest do
  @moduledoc """
  The private key an unedited original is copied to.

  A revert hands the backup's `unedited_…` keys back to the file, so the next
  first edit copies FROM such a key. The prefix has to be replaced then, not
  stacked: stacking added 42 characters per edit-after-revert cycle until the
  key outgrew `file_instances.file_name` (varchar(255)) and the file could
  never be edited again.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.ApplyImageEditJob

  @key "ab/cd/0123456789abcdef0123456789abcdef/" <>
         String.duplicate("f", 64) <> "_thumbnail_webp.webp"

  test "stays in the directory and is recognised as an unedited key" do
    copy = ApplyImageEditJob.unedited_key(@key)

    assert Path.dirname(copy) == Path.dirname(@key)
    assert ApplyImageEditJob.unedited_key?(copy)
    assert String.ends_with?(copy, "_" <> Path.basename(@key))
  end

  test "is a fresh key every time" do
    refute ApplyImageEditJob.unedited_key(@key) == ApplyImageEditJob.unedited_key(@key)
  end

  test "does not grow across edit-after-revert cycles" do
    first = ApplyImageEditJob.unedited_key(@key)

    last = Enum.reduce(1..10, first, fn _, key -> ApplyImageEditJob.unedited_key(key) end)

    assert String.length(last) == String.length(first)
    assert String.length(last) <= 255
    refute last == first
  end

  test "leaves a name that merely starts with the word alone" do
    key = "ab/cd/x/unedited_notes.png"

    assert String.ends_with?(ApplyImageEditJob.unedited_key(key), "_unedited_notes.png")
  end
end
