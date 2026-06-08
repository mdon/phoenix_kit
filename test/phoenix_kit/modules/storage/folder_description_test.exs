defmodule PhoenixKit.Modules.Storage.FolderDescriptionTest do
  @moduledoc """
  Covers the folder `description` feature (V132): the schema casts/validates
  it, and the context round-trips it to the DB column. Guards against the
  column, schema field, and changeset cast drifting out of sync.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder

  describe "changeset" do
    test "casts a description" do
      cs = Folder.changeset(%Folder{}, %{name: "Docs", description: "Important stuff"})
      assert cs.valid?
      assert get_change(cs, :description) == "Important stuff"
    end

    test "rejects an over-long description" do
      cs = Folder.changeset(%Folder{}, %{name: "Docs", description: String.duplicate("a", 2001)})
      refute cs.valid?
      assert %{description: _} = errors_on(cs)
    end

    test "description is optional" do
      assert Folder.changeset(%Folder{}, %{name: "Docs"}).valid?
    end
  end

  describe "update_folder/2" do
    test "persists and clears a description (round-trips the V132 column)" do
      {:ok, folder} = Storage.create_folder(%{name: "Reports"})

      {:ok, updated} = Storage.update_folder(folder, %{description: "Quarterly reports"})
      assert updated.description == "Quarterly reports"
      assert Storage.get_folder(folder.uuid).description == "Quarterly reports"

      {:ok, cleared} = Storage.update_folder(updated, %{description: nil})
      assert cleared.description == nil
    end
  end
end
