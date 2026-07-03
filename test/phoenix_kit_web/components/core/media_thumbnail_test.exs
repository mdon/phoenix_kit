defmodule PhoenixKitWeb.Components.Core.MediaThumbnailTest do
  @moduledoc """
  Tests `Components.Core.MediaThumbnail.resolve_url/2` — the pure URL-picking
  logic behind the `<.thumbnail_url>` component.

  Locks in the variant-priority chains per size mode, especially `:card` (the
  large grid/stack cards introduced in PR #609): it prefers the sharp
  `thumbnail_annotated` (400px) / `small` (300px) / `medium` variants, but when
  those are absent it must fall back to the light 150px `thumbnail` BEFORE the
  full-res `original`, so a card never loads a multi-megabyte original while a
  cheap thumbnail exists.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Components.Core.MediaThumbnail

  defp image(urls), do: %{file_type: "image", urls: urls}

  describe "resolve_url/2 — video" do
    test "always uses the video thumbnail regardless of size" do
      file = %{file_type: "video", urls: %{"video_thumbnail" => "/v.jpg", "small" => "/s.jpg"}}

      for size <- [:small, :card, :medium] do
        assert MediaThumbnail.resolve_url(file, size) == "/v.jpg"
      end
    end
  end

  describe "resolve_url/2 — image :small (list rows, selectors)" do
    test "prefers the baked annotated thumbnail, then plain 150px thumbnail" do
      assert MediaThumbnail.resolve_url(
               image(%{"thumbnail_annotated" => "/a.png", "thumbnail" => "/t.jpg"}),
               :small
             ) == "/a.png"

      assert MediaThumbnail.resolve_url(
               image(%{"thumbnail" => "/t.jpg", "small" => "/s.jpg"}),
               :small
             ) == "/t.jpg"
    end
  end

  describe "resolve_url/2 — image :card (grid/stack cards)" do
    test "prefers the baked 400px annotated thumbnail when present" do
      assert MediaThumbnail.resolve_url(
               image(%{
                 "thumbnail_annotated" => "/a.png",
                 "small" => "/s.jpg",
                 "thumbnail" => "/t.jpg",
                 "original" => "/o.jpg"
               }),
               :card
             ) == "/a.png"
    end

    test "prefers the 300px small over the blurry 150px thumbnail" do
      assert MediaThumbnail.resolve_url(
               image(%{"small" => "/s.jpg", "thumbnail" => "/t.jpg", "original" => "/o.jpg"}),
               :card
             ) == "/s.jpg"
    end

    test "uses medium when small is missing" do
      assert MediaThumbnail.resolve_url(
               image(%{"medium" => "/m.jpg", "thumbnail" => "/t.jpg", "original" => "/o.jpg"}),
               :card
             ) == "/m.jpg"
    end

    test "falls back to the light 150px thumbnail before the full-res original" do
      # Regression guard (PR #609 follow-up): a file with only thumbnail +
      # original must NOT load the heavy original on a card.
      assert MediaThumbnail.resolve_url(
               image(%{"thumbnail" => "/t.jpg", "original" => "/o.jpg"}),
               :card
             ) == "/t.jpg"
    end

    test "uses the original only as the true last resort" do
      assert MediaThumbnail.resolve_url(image(%{"original" => "/o.jpg"}), :card) == "/o.jpg"
    end
  end

  describe "resolve_url/2 — image :medium (gallery/preview)" do
    test "prefers medium, then thumbnail, then original" do
      assert MediaThumbnail.resolve_url(
               image(%{"medium" => "/m.jpg", "thumbnail" => "/t.jpg"}),
               :medium
             ) == "/m.jpg"

      assert MediaThumbnail.resolve_url(
               image(%{"thumbnail" => "/t.jpg", "original" => "/o.jpg"}),
               :medium
             ) == "/t.jpg"
    end
  end

  describe "resolve_url/2 — non-image (documents/PDFs)" do
    test ":small prefers thumbnail then small" do
      assert MediaThumbnail.resolve_url(%{urls: %{"thumbnail" => "/t.jpg"}}, :small) == "/t.jpg"
    end

    test ":card prefers small, then thumbnail, then medium (never the original)" do
      assert MediaThumbnail.resolve_url(
               %{urls: %{"small" => "/s.jpg", "thumbnail" => "/t.jpg", "medium" => "/m.jpg"}},
               :card
             ) == "/s.jpg"

      # A document with only an original renders the placeholder, not the raw
      # file as an <img src> — so :card returns nil here.
      assert MediaThumbnail.resolve_url(%{urls: %{"original" => "/o.pdf"}}, :card) == nil
    end
  end

  describe "resolve_url/2 — fallback" do
    test "returns nil for unknown shapes" do
      assert MediaThumbnail.resolve_url(%{}, :card) == nil
      assert MediaThumbnail.resolve_url(%{file_type: "image"}, :small) == nil
    end
  end
end
