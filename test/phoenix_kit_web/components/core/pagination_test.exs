defmodule PhoenixKitWeb.Components.Core.PaginationTest do
  @moduledoc """
  Render tests for `<.pagination>` and `<.pagination_controls>`.

  Both share the private `pagination_range/2` helper, which used to build an
  UNCLAMPED `current_page ± 2` range: with `current_page` far beyond
  `total_pages` (a stale bookmark, a crawled/forged URL, or simply typing a
  huge number), `start_page..end_page` picked a DESCENDING step (Elixir's
  `a..b` auto-selects step -1 whenever `a > b`) spanning billions of
  integers, and the `:for` loop below it allocated a `<.link>` per step
  until the VM ran out of memory — a real, reproduced-in-production OOM
  (`GET /admin/crm/contacts?page=9999999999` killed the BEAM), not a
  theoretical one. The fix clamps `current_page` into `[1, total_pages]`
  before computing the range, plus an explicit `//1` step as a second,
  independent guard.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.Core.Pagination, only: [pagination: 1, pagination_controls: 1]

  # Page-number links carry `page=N` in their href — a precise, whitespace-
  # proof way to check which page numbers rendered (the visible text node
  # is pretty-printed with surrounding newlines/indentation by HEEx, so a
  # bare `>N<` substring match is fragile).
  defp has_page_link?(html, n), do: html =~ "page=#{n}\""

  describe "pagination/1" do
    test "renders nothing when total_pages <= 1" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.pagination current_page={1} total_pages={1} base_path="/admin/x" />
        """)

      assert String.trim(result) == ""
    end

    test "renders page numbers within ±2 of current_page" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.pagination current_page={5} total_pages={10} base_path="/admin/x" />
        """)

      for n <- 3..7, do: assert(has_page_link?(result, n))
      refute has_page_link?(result, 2)
      refute has_page_link?(result, 8)
      assert result =~ "« Prev"
      assert result =~ "Next »"
    end

    # The actual production crash: a page number wildly beyond total_pages.
    test "current_page far beyond total_pages doesn't hang or blow up the range" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.pagination current_page={9_999_999_999} total_pages={56} base_path="/admin/x" />
        """)

      # Clamped to the last page (56) — the ±2 window around it, not a
      # multi-billion-element crawl back down to page 1.
      assert has_page_link?(result, 56)
      assert has_page_link?(result, 54)
      refute has_page_link?(result, 1)
      refute result =~ "Next »"
    end

    test "total_pages = 0 doesn't crash (treated as 1 page, renders nothing)" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.pagination current_page={1} total_pages={0} base_path="/admin/x" />
        """)

      assert String.trim(result) == ""
    end

    test "total_pages = 0 with a huge current_page doesn't crash either" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.pagination current_page={9_999_999_999} total_pages={0} base_path="/admin/x" />
        """)

      assert String.trim(result) == ""
    end
  end

  describe "pagination_controls/1" do
    # Shares pagination_range/2 with pagination/1, so it needs its own
    # regression coverage for the same crash.
    test "current_page far beyond total_pages doesn't hang or blow up the range" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.pagination_controls
          page={9_999_999_999}
          total_pages={56}
          build_url={fn n -> "/admin/x?page=#{n}" end}
        />
        """)

      assert has_page_link?(result, 56)
      assert has_page_link?(result, 54)
      refute has_page_link?(result, 1)
    end

    # Used to render a clickable "1" and a "Prev" button for a genuinely
    # empty list (total_pages == 0) — garbage controls for nothing to
    # paginate. Now guarded the same way as pagination/1.
    test "total_pages = 0 renders nothing" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.pagination_controls
          page={9_999_999_999}
          total_pages={0}
          build_url={fn n -> "/admin/x?page=#{n}" end}
        />
        """)

      assert String.trim(result) == ""
    end

    test "renders Prev/Next and a normal page-number range" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.pagination_controls
          page={5}
          total_pages={10}
          build_url={fn n -> "/admin/x?page=#{n}" end}
        />
        """)

      assert result =~ "« Prev"
      assert result =~ "Next »"
      for n <- 3..7, do: assert(has_page_link?(result, n))
    end
  end
end
