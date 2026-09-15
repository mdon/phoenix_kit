defmodule PhoenixKit.Modules.Storage.PdfProcessorTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.PdfProcessor

  describe "file_attrs/2" do
    test "nests pdfinfo fields under :metadata instead of the row's top level" do
      pdf = %{"page_count" => 6, "author" => "Hydroforce", "creation_date" => "Thu May 14 2026"}

      assert PdfProcessor.file_attrs(nil, pdf) == %{metadata: pdf}
    end

    test "merges over metadata the file already carries" do
      assert PdfProcessor.file_attrs(%{"source" => "import"}, %{"page_count" => 2}) ==
               %{metadata: %{"source" => "import", "page_count" => 2}}
    end

    test "an empty pdfinfo result (pdfinfo missing or failed) keeps existing metadata" do
      assert PdfProcessor.file_attrs(%{"a" => 1}, %{}) == %{metadata: %{"a" => 1}}
    end

    test "the result casts cleanly alongside the job's atom-keyed status" do
      attrs = Map.merge(%{status: "active"}, PdfProcessor.file_attrs(nil, %{"page_count" => 1}))

      changeset = StorageFile.changeset(%StorageFile{}, attrs)

      assert Ecto.Changeset.get_change(changeset, :metadata) == %{"page_count" => 1}
      assert Ecto.Changeset.get_change(changeset, :status) == "active"
    end
  end
end
