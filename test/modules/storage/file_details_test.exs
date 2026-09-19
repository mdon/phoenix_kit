defmodule PhoenixKit.Modules.Storage.FileDetailsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.File
  alias PhoenixKit.Modules.Storage.FileDetails

  @data %{
    "_primary_language" => "en-US",
    "en-US" => %{"_title" => "Harbour", "_alt" => "Boats in a harbour"},
    "et" => %{"_title" => "Sadam", "_alt" => "Paadid sadamas"}
  }

  defp file(metadata, data \\ %{}), do: %File{metadata: metadata, data: data}

  describe "reading" do
    test "a translation wins over the primary text" do
      file = file(%{"title" => "Harbour", "alt" => "Boats in a harbour"}, @data)

      assert FileDetails.translated_title(file, "et") == "Sadam"
      assert FileDetails.translated_alt(file, "et") == "Paadid sadamas"
    end

    test "a field with no translation falls back to the primary text" do
      file = file(%{"title" => "Harbour", "description" => "Tallinn, 2026"}, @data)

      assert FileDetails.translated_description(file, "et") == "Tallinn, 2026"
      assert FileDetails.translated_title(file, "lv") == "Harbour"
    end

    test "a dialect finds the entry stored under its base code" do
      assert FileDetails.translated_title(file(%{"title" => "Harbour"}, @data), "et-EE") ==
               "Sadam"
    end

    test "no locale reads the primary text" do
      assert FileDetails.translated_title(file(%{"title" => "Harbour"}, @data)) == "Harbour"
    end

    test "the alt text is never the file name: none is an empty string" do
      file = %File{original_file_name: "IMG_0042.jpg", metadata: nil, data: %{}}

      assert FileDetails.translated_alt(file, "et") == ""
      assert FileDetails.translated_title(file, "et") == nil
    end

    test "a blank or non-text value reads as absent" do
      file = file(%{"title" => "  ", "description" => 42}, %{})

      assert FileDetails.for_locale(file, "en") == %{title: nil, alt: "", description: nil}
    end

    test "a row from before V199 (nil data) still reads" do
      assert FileDetails.translated_title(file(%{"title" => "Harbour"}, nil), "et") == "Harbour"
    end
  end

  describe "changeset/2" do
    test "an absent key keeps its current value" do
      details = FileDetails.from_file(file(%{"title" => "Harbour", "alt" => "Boats"}))

      changed =
        details |> FileDetails.changeset(%{"title" => "Port"}) |> Ecto.Changeset.apply_changes()

      assert changed.title == "Port"
      assert changed.alt == "Boats"
    end

    test "strips null bytes and surrounding whitespace" do
      changeset = FileDetails.changeset(%FileDetails{}, %{"alt" => "  Bo\x00ats \n"})

      assert Ecto.Changeset.get_change(changeset, :alt) == "Boats"
    end

    test "limits the length of the primary text and of a translation" do
      long = String.duplicate("a", 501)

      refute FileDetails.changeset(%FileDetails{}, %{"alt" => long}).valid?

      data = %{"_primary_language" => "en", "en" => %{}, "et" => %{"_alt" => long}}
      changeset = FileDetails.changeset(%FileDetails{}, %{"data" => data})

      assert {"a translation is too long", _} = changeset.errors[:data]
    end

    test "keeps only the details' own keys in data" do
      data = %{
        "_primary_language" => "en",
        "en" => %{"_title" => "Harbour", "rotation" => 90},
        "et" => %{"_title" => "Sadam", "_alt" => "", "_slug" => "sadam"},
        "junk" => "value"
      }

      changeset = FileDetails.changeset(%FileDetails{}, %{"title" => "Harbour", "data" => data})

      assert Ecto.Changeset.get_field(changeset, :data) == %{
               "_primary_language" => "en",
               "en" => %{"_title" => "Harbour"},
               "et" => %{"_title" => "Sadam"}
             }
    end

    test "a save without data refreshes the multilang primary entry" do
      details = FileDetails.from_file(file(%{"title" => "Harbour"}, @data))

      changed =
        details |> FileDetails.changeset(%{"title" => "Port"}) |> Ecto.Changeset.apply_changes()

      assert changed.data["en-US"] == %{"_title" => "Port"}
      assert changed.data["et"] == @data["et"]
    end

    test "flat data is left alone" do
      changeset = FileDetails.changeset(%FileDetails{}, %{"title" => "Harbour"})

      assert Ecto.Changeset.get_field(changeset, :data) == %{}
    end
  end

  describe "file_attrs/2" do
    test "merges the text into metadata and keeps every other key" do
      file = file(%{"rotation" => 90, "tags" => ["sea"], "title" => "Old"})
      details = %FileDetails{title: "Harbour", alt: "Boats", description: nil, data: @data}

      assert FileDetails.file_attrs(file, details) == %{
               metadata: %{
                 "rotation" => 90,
                 "tags" => ["sea"],
                 "title" => "Harbour",
                 "alt" => "Boats",
                 "description" => ""
               },
               data: @data
             }
    end
  end
end
