defmodule PhoenixKit.Integration.Storage.URLSignerTest do
  @moduledoc """
  Integration tests for `PhoenixKit.Modules.Storage.URLSigner.put_dzi_url/3`.

  `put_dzi_url/3` is the single source of truth for the signed `"dzi"` deep-zoom
  manifest URL shared by the media browser, detail page, and lightbox. Its
  output depends on whether the variant set of the file's library makes
  tiles (V205; the Default set's flag is what the
  `storage_tile_generation_enabled` setting was), so these run against the
  real Repo via `DataCase`, with a file row in Media under `@file_uuid`.
  """

  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, URLSigner, VariantSets}
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  @file_uuid "018e3c4a-9f6b-7890-abcd-ef1234567890"
  @setting "storage_tile_generation_enabled"

  setup do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "dzi-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, _} =
      %Storage.File{uuid: @file_uuid}
      |> Storage.File.changeset(%{
        user_uuid: user.uuid,
        original_file_name: "a.png",
        file_name: "a.png",
        file_path: "x",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active"
      })
      |> Repo.insert()

    :ok
  end

  defp enable_tiles, do: Storage.set_tile_generation(true)
  defp disable_tiles, do: Storage.set_tile_generation(false)

  # The dzi URL the impl is expected to build for this file — derived from the
  # same primitives (`generate_token/2` + `Routes.path/2`, `locale: :none`) so
  # the assertion pins the contract (path shape + token namespace) rather than a
  # secret-dependent literal.
  defp expected_dzi(file_uuid),
    do:
      Routes.path("/tiles/#{URLSigner.generate_token(file_uuid, "dzi")}/#{file_uuid}.dzi",
        locale: :none
      )

  describe "put_dzi_url/3 — tile generation enabled" do
    setup do
      enable_tiles()
      :ok
    end

    test "adds a signed dzi manifest URL for an image, preserving existing urls" do
      urls =
        URLSigner.put_dzi_url(
          %{"original" => "/file/o", "medium" => "/file/m"},
          @file_uuid,
          "image/png"
        )

      assert urls["dzi"] == expected_dzi(@file_uuid)
      # existing keys are untouched
      assert urls["original"] == "/file/o"
      assert urls["medium"] == "/file/m"
    end

    test "works across image mime subtypes" do
      for mime <- ~w(image/jpeg image/webp image/gif image/svg+xml image/heic) do
        urls = URLSigner.put_dzi_url(%{}, @file_uuid, mime)

        assert urls["dzi"] == expected_dzi(@file_uuid),
               "expected dzi for #{inspect(mime)}"
      end
    end

    test "is stable across calls for the same file (idempotent on the dzi key)" do
      once = URLSigner.put_dzi_url(%{}, @file_uuid, "image/png")
      twice = URLSigner.put_dzi_url(once, @file_uuid, "image/png")

      assert twice["dzi"] == once["dzi"]
    end

    test "leaves non-image mime types unchanged" do
      for mime <- ~w(video/mp4 audio/mpeg application/pdf text/plain image) do
        # "image" (no slash) must NOT match the `String.starts_with?("image/")` guard
        urls = URLSigner.put_dzi_url(%{"original" => "/file/o"}, @file_uuid, mime)
        refute Map.has_key?(urls, "dzi"), "unexpected dzi for #{inspect(mime)}"
        assert urls["original"] == "/file/o"
      end
    end

    test "leaves the map unchanged when mime_type is nil" do
      urls = URLSigner.put_dzi_url(%{"original" => "/file/o"}, @file_uuid, nil)
      refute Map.has_key?(urls, "dzi")
    end
  end

  describe "put_dzi_url/3 — tile generation disabled / unset" do
    test "leaves the map unchanged when the Default set makes no tiles" do
      disable_tiles()

      urls = URLSigner.put_dzi_url(%{"original" => "/file/o"}, @file_uuid, "image/png")
      refute Map.has_key?(urls, "dzi")
      assert urls["original"] == "/file/o"
    end

    test "the Default set makes no tiles unless turned on" do
      # V205 seeded the Default from the setting, which defaults to false.
      urls = URLSigner.put_dzi_url(%{"original" => "/file/o"}, @file_uuid, "image/jpeg")
      refute Map.has_key?(urls, "dzi")
    end

    test "the old setting row alone no longer turns tiles on" do
      Settings.update_setting(@setting, "true")

      urls = URLSigner.put_dzi_url(%{}, @file_uuid, "image/png")
      refute Map.has_key?(urls, "dzi")
    end

    test "an unknown file gets no tiles" do
      enable_tiles()

      urls = URLSigner.put_dzi_url(%{}, Ecto.UUID.generate(), "image/png")
      refute Map.has_key?(urls, "dzi")
    end
  end

  describe "put_dzi_url/3 — per library" do
    test "follows the variant set of the file's library" do
      disable_tiles()

      {:ok, library} =
        Libraries.create_system_library(%{name: "Tiles #{System.unique_integer()}"})

      {:ok, set} = VariantSets.create_variant_set(%{name: "Zoom", generate_tiles: true})
      {:ok, _} = VariantSets.set_library_variant_set(library, set.uuid)
      {:ok, _} = Storage.update_file(Storage.get_file(@file_uuid), %{library_uuid: library.uuid})

      assert URLSigner.put_dzi_url(%{}, @file_uuid, "image/png")["dzi"] ==
               expected_dzi(@file_uuid)
    end

    test "`tiles:` is taken as given" do
      disable_tiles()
      assert URLSigner.put_dzi_url(%{}, @file_uuid, "image/png", tiles: true)["dzi"]
      enable_tiles()
      refute URLSigner.put_dzi_url(%{}, @file_uuid, "image/png", tiles: false)["dzi"]
    end
  end

  describe "put_dzi_url/3 — guard / fallback clauses" do
    setup do
      enable_tiles()
      :ok
    end

    test "non-map urls is returned as-is" do
      assert URLSigner.put_dzi_url(nil, @file_uuid, "image/png") == nil
    end

    test "non-binary file_uuid leaves the map unchanged" do
      urls = URLSigner.put_dzi_url(%{"original" => "/file/o"}, nil, "image/png")
      refute Map.has_key?(urls, "dzi")
      assert urls["original"] == "/file/o"
    end
  end
end
