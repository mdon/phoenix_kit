defmodule PhoenixKit.Integration.Storage.URLSignerTest do
  @moduledoc """
  Integration tests for `PhoenixKit.Modules.Storage.URLSigner.put_dzi_url/3`.

  `put_dzi_url/3` is the single source of truth for the signed `"dzi"` deep-zoom
  manifest URL shared by the media browser, detail page, and lightbox. Its
  output depends on the `storage_tile_generation_enabled` setting (DB-backed),
  so these run against the real Repo via `DataCase` — the non-cached
  `Settings.get_setting/2` the helper reads is sandbox-safe and unaffected by
  the settings cache `update_setting/2` invalidates.
  """

  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @file_uuid "018e3c4a-9f6b-7890-abcd-ef1234567890"
  @setting "storage_tile_generation_enabled"

  defp enable_tiles, do: Settings.update_setting(@setting, "true")
  defp disable_tiles, do: Settings.update_setting(@setting, "false")

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
    test "leaves the map unchanged when the setting is explicitly false" do
      disable_tiles()

      urls = URLSigner.put_dzi_url(%{"original" => "/file/o"}, @file_uuid, "image/png")
      refute Map.has_key?(urls, "dzi")
      assert urls["original"] == "/file/o"
    end

    test "treats an unset setting as disabled (default false)" do
      # Fresh sandbox transaction — no setting row, so get_setting/2 falls back
      # to its "false" default and no dzi is added.
      urls = URLSigner.put_dzi_url(%{"original" => "/file/o"}, @file_uuid, "image/jpeg")
      refute Map.has_key?(urls, "dzi")
    end

    test "does not treat a truthy-but-not-\"true\" value as enabled" do
      # The check is `== "true"` (string), not a boolean parse — guard against a
      # future value-shape drift (e.g. "1", "on", "yes") silently enabling tiles.
      Settings.update_setting(@setting, "1")

      urls = URLSigner.put_dzi_url(%{}, @file_uuid, "image/png")
      refute Map.has_key?(urls, "dzi")
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
