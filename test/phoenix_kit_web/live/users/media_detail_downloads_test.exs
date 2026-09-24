defmodule PhoenixKitWeb.Live.Users.MediaDetailDownloadsTest do
  @moduledoc """
  The details page's download list (#872): the picture's sizes, then the
  annotated copies, and every other variant the file has — a custom size, a
  video's — still offered after the standard ones. A tile manifest, the
  grid's square crop and the retired `annotated` slot are not downloads.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Live.Users.MediaDetail

  defp urls(names), do: Map.new(names, &{&1, "/file/f/#{&1}/t"})

  defp variants(groups),
    do: Map.new(groups, fn {key, _title, rows} -> {key, Enum.map(rows, & &1.variant)} end)

  test "standard sizes first, custom ones after them, burns on their own" do
    names = ~w(thumbnail original grid_2x medium burned 720p large burned_large)

    assert variants(MediaDetail.download_groups(urls(names), %{})) == %{
             picture: ~w(original large medium thumbnail 720p grid_2x),
             annotated: ~w(burned_large burned)
           }
  end

  test "manifests, the grid crop and the retired slot are left out" do
    names = ~w(original dzi thumbnail_annotated annotated)

    assert variants(MediaDetail.download_groups(urls(names), %{})) == %{picture: ["original"]}
  end
end
