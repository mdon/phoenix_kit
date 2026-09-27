defmodule PhoenixKit.Modules.Shared.RenderCacheTest do
  @moduledoc """
  A missing file is a finished placeholder. A lookup that raises is not,
  and the next render on the same process starts clean.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Shared.Components.Image
  alias PhoenixKit.Modules.Shared.RenderCache

  test "a successful nested render preserves an earlier outer failure" do
    assert {:retry, :page} =
             RenderCache.take(fn ->
               RenderCache.lookup_failed()
               assert {:ok, :fragment} = RenderCache.take(fn -> :fragment end)
               :page
             end)
  end

  test "a failed nested render marks the enclosing render for retry" do
    assert {:retry, :page} =
             RenderCache.take(fn ->
               assert {:retry, :fragment} =
                        RenderCache.take(fn ->
                          RenderCache.lookup_failed()
                          :fragment
                        end)

               :page
             end)
  end

  test "an interrupted nested render propagates its failure and cleans up" do
    assert {:retry, :page} =
             RenderCache.take(fn ->
               assert_raise RuntimeError, "render failed", fn ->
                 RenderCache.take(fn ->
                   RenderCache.lookup_failed()
                   raise "render failed"
                 end)
               end

               :page
             end)

    assert {:ok, :clean} = RenderCache.take(fn -> :clean end)
  end

  test "exits and throws from rendering propagate and leave the next render clean" do
    assert catch_exit(
             RenderCache.take(fn ->
               RenderCache.lookup_failed()
               exit(:stopped)
             end)
           ) ==
             :stopped

    assert {:ok, :clean} = RenderCache.take(fn -> :clean end)

    assert catch_throw(
             RenderCache.take(fn ->
               RenderCache.lookup_failed()
               throw(:stopped)
             end)
           ) ==
             :stopped

    assert {:ok, :clean} = RenderCache.take(fn -> :clean end)
  end

  test "a lookup that returns nil is cacheable" do
    assert {:ok, nil} = RenderCache.take(fn -> RenderCache.lookup(fn -> nil end, :fallback) end)
  end

  test "a lookup that raises returns the fallback and must be tried again" do
    assert {:retry, :fallback} =
             RenderCache.take(fn ->
               RenderCache.lookup(
                 fn -> raise "column placed_profile_uuid does not exist" end,
                 :fallback
               )
             end)
  end

  test "a lookup that exits is the same kind of failure" do
    assert {:retry, :fallback} =
             RenderCache.take(fn ->
               RenderCache.lookup(fn -> exit(:db_down) end, :fallback)
             end)
  end

  test "the mark does not leak into the next render on this process" do
    assert {:retry, :fallback} =
             RenderCache.take(fn ->
               RenderCache.lookup(fn -> raise "db" end, :fallback)
             end)

    assert {:ok, :clean} = RenderCache.take(fn -> :clean end)
  end

  test "a direct src never looks a file up and stays cacheable" do
    assigns = %{attrs: %{"src" => "/logo.png", "alt" => "Logo"}}

    {status, html} =
      RenderCache.take(fn ->
        rendered_to_string(~H"<Image.render attributes={@attrs} />")
      end)

    assert status == :ok
    assert html =~ ~s(src="/logo.png")
    refute html =~ "Image not available"
  end

  test "an image lookup that raises renders the placeholder and is not cacheable" do
    # Not a uuid, so the file query cannot succeed whether or not the
    # repo is up: it raises, and that must not look like a missing file.
    assigns = %{attrs: %{"file_uuid" => "not-a-uuid", "alt" => "Boat"}}

    {status, html} =
      RenderCache.take(fn ->
        rendered_to_string(~H"<Image.render attributes={@attrs} />")
      end)

    assert status == :retry
    assert html =~ "Image not available"
    refute html =~ "<img"
  end
end
