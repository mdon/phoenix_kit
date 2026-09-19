defmodule PhoenixKit.Modules.Storage.FileDetailsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.File
  alias PhoenixKit.Modules.Storage.FileDetails

  @en [primary: "en-US"]
  @et [primary: "et"]

  @data %{
    "en-US" => %{"title" => "Harbour", "alt" => "Boats in a harbour", "description" => "Tallinn"},
    "et" => %{"title" => "Sadam", "alt" => "Paadid sadamas"}
  }

  defp file(metadata, data \\ %{}), do: %File{metadata: metadata, data: data}

  describe "reading" do
    test "a language reads its own text" do
      assert FileDetails.translated_title(file(%{}, @data), "et", @en) == "Sadam"
      assert FileDetails.translated_alt(file(%{}, @data), "et", @en) == "Paadid sadamas"
    end

    test "a missing field falls back to the primary language, field by field" do
      assert FileDetails.translated_description(file(%{}, @data), "et", @en) == "Tallinn"
      assert FileDetails.translated_title(file(%{}, @data), "lv", @en) == "Harbour"
    end

    test "with no text in the primary language either, any language stands in" do
      file = file(%{}, %{"et" => %{"alt" => "Paadid sadamas"}})

      assert FileDetails.translated_alt(file, "lv", @en) == "Paadid sadamas"
    end

    test "a dialect finds the entry under its base code, and the reverse" do
      assert FileDetails.translated_title(file(%{}, @data), "et-EE", @en) == "Sadam"
      assert FileDetails.translated_title(file(%{}, @data), "en", @et) == "Harbour"
    end

    test "no locale reads the primary language" do
      assert FileDetails.translated_title(file(%{}, @data), nil, @et) == "Sadam"
    end

    test "changing the site's primary language converts nothing: the same data reads right" do
      file = file(%{"title" => "Harbour"}, @data)

      assert FileDetails.for_locale(file, "lv", @en).title == "Harbour"
      assert FileDetails.for_locale(file, "lv", @et).title == "Sadam"
      assert FileDetails.for_locale(file, "en-US", @et).title == "Harbour"
    end

    test "the alt text is never the file name: none is an empty string" do
      file = %File{original_file_name: "IMG_0042.jpg", metadata: nil, data: %{}}

      assert FileDetails.for_locale(file, "et", @en) == %{title: nil, alt: "", description: nil}
    end

    test "a file from before V199 reads its metadata text as the primary language's" do
      for data <- [%{}, nil] do
        file = file(%{"title" => "Harbour", "description" => 42, "alt" => "  "}, data)

        assert FileDetails.for_locale(file, "et", @en) ==
                 %{title: "Harbour", alt: "", description: nil}
      end
    end

    test "once data holds text, metadata is no longer read" do
      file = file(%{"title" => "Stale copy"}, %{"et" => %{"alt" => "Paadid"}})

      assert FileDetails.translated_title(file, "en-US", @en) == nil
    end
  end

  describe "content_language/2" do
    @site [languages: ["en-US", "et"], primary: "en-US"]

    test "is the enabled language the locale names, at whatever precision" do
      assert FileDetails.content_language("et", @site) == "et"
      assert FileDetails.content_language("et-EE", @site) == "et"
      assert FileDetails.content_language("en", @site) == "en-US"
    end

    test "a locale that is no enabled language, or none at all, is the primary language" do
      assert FileDetails.content_language("lv", @site) == "en-US"
      assert FileDetails.content_language(nil, @site) == "en-US"
    end
  end

  describe "from_file/3" do
    test "is the language's own text, with no fallback" do
      assert FileDetails.from_file(file(%{}, @data), "et", @en) ==
               %FileDetails{title: "Sadam", alt: "Paadid sadamas", description: nil}

      assert FileDetails.from_file(file(%{}, @data), "lv", @en) == %FileDetails{}
    end

    test "a file from before V199 shows its metadata text on the primary tab only" do
      legacy = file(%{"title" => "Harbour"})

      assert FileDetails.from_file(legacy, "en-US", @en).title == "Harbour"
      assert FileDetails.from_file(legacy, nil, @en).title == "Harbour"
      assert FileDetails.from_file(legacy, "et", @en).title == nil
    end

    test "after the primary language changes, the new primary tab is not filled with the old text" do
      file = file(%{"title" => "Harbour"}, %{"en-US" => %{"title" => "Harbour"}})

      assert FileDetails.from_file(file, "et", @et) == %FileDetails{}
    end
  end

  describe "changeset/2" do
    test "an absent key keeps its current value" do
      changed =
        %FileDetails{title: "Harbour", alt: "Boats"}
        |> FileDetails.changeset(%{"title" => "Port"})
        |> Ecto.Changeset.apply_changes()

      assert changed == %FileDetails{title: "Port", alt: "Boats"}
    end

    test "strips null bytes and surrounding whitespace" do
      changeset = FileDetails.changeset(%FileDetails{}, %{"alt" => "  Bo\x00ats \n"})

      assert Ecto.Changeset.get_change(changeset, :alt) == "Boats"
    end

    test "limits each field's length" do
      for {field, max} <- [{"title", 255}, {"alt", 500}, {"description", 5000}] do
        attrs = %{field => String.duplicate("a", max + 1)}
        refute FileDetails.changeset(%FileDetails{}, attrs).valid?
      end
    end
  end

  describe "file_attrs/4" do
    test "replaces one language and leaves the others alone" do
      details = %FileDetails{title: "Sadam tormis", alt: nil}

      assert FileDetails.file_attrs(file(%{"rotation" => 90}, @data), details, "et", @en) == %{
               metadata: %{"rotation" => 90},
               data: %{"en-US" => @data["en-US"], "et" => %{"title" => "Sadam tormis"}}
             }
    end

    test "the primary language is copied into metadata, a cleared field as an empty string" do
      details = %FileDetails{title: "Port", alt: "Boats"}
      file = file(%{"rotation" => 90, "tags" => ["sea"], "description" => "Old"}, @data)

      assert %{metadata: metadata, data: data} = FileDetails.file_attrs(file, details, nil, @en)

      assert metadata == %{
               "rotation" => 90,
               "tags" => ["sea"],
               "title" => "Port",
               "alt" => "Boats",
               "description" => ""
             }

      assert data == %{"en-US" => %{"title" => "Port", "alt" => "Boats"}, "et" => @data["et"]}
    end

    test "a language left with no text is removed" do
      attrs = FileDetails.file_attrs(file(%{}, @data), %FileDetails{}, "et", @en)

      assert attrs.data == %{"en-US" => @data["en-US"]}
    end

    test "a translation saved first on a file from before V199 keeps its metadata text" do
      legacy = file(%{"title" => "Harbour", "rotation" => 90})
      attrs = FileDetails.file_attrs(legacy, %FileDetails{title: "Sadam"}, "et", @en)

      assert attrs.data == %{"en-US" => %{"title" => "Harbour"}, "et" => %{"title" => "Sadam"}}
      assert attrs.metadata == %{"title" => "Harbour", "rotation" => 90}
    end

    test "writing a code replaces the same language stored at another precision, not a sibling dialect" do
      data = %{"en" => %{"title" => "Old"}, "et" => %{"title" => "Sadam"}}
      attrs = FileDetails.file_attrs(file(%{}, data), %FileDetails{title: "New"}, "en-US", @en)
      assert attrs.data == %{"en-US" => %{"title" => "New"}, "et" => %{"title" => "Sadam"}}

      data = %{"en-GB" => %{"title" => "Harbour"}}
      attrs = FileDetails.file_attrs(file(%{}, data), %FileDetails{title: "Harbor"}, "en-US", @en)

      assert attrs.data == %{
               "en-GB" => %{"title" => "Harbour"},
               "en-US" => %{"title" => "Harbor"}
             }
    end
  end
end
