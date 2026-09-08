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

  import PhoenixKitWeb.Components.Core.Pagination,
    only: [
      pagination: 1,
      pagination_controls: 1,
      pagination_info: 1,
      page_size_selector: 1
    ]

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

  describe "pagination_info/1" do
    defp info(assigns) do
      assigns = Map.put_new(assigns, :noun_plural, nil)

      ~H"""
      <.pagination_info
        page={@page}
        per_page={@per_page}
        total_count={@total_count}
        noun_plural={@noun_plural}
      />
      """
      |> rendered_to_string()
    end

    test "counts results by default and drops ' of N' on a single page" do
      assert info(%{page: 2, per_page: 25, total_count: 100}) =~
               "Showing 26 to 50 of 100 results"

      assert info(%{page: 1, per_page: 25, total_count: 4}) =~ "Showing 1 to 4 results"
      assert info(%{page: 1, per_page: 25, total_count: 0}) =~ "No results"
    end

    test "noun_plural names what is counted in every branch" do
      assert info(%{page: 1, per_page: 20, total_count: 40, noun_plural: "sessions"}) =~
               "Showing 1 to 20 of 40 sessions"

      assert info(%{page: 1, per_page: 20, total_count: 3, noun_plural: "sessions"}) =~
               "Showing 1 to 3 sessions"

      assert info(%{page: 1, per_page: 20, total_count: 0, noun_plural: "sessions"}) =~
               "No sessions"
    end
  end

  describe "page_size_selector/1" do
    test "renders the default options in a phx-change form with the current value selected" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.page_size_selector value={25} />
        """)

      assert result =~ ~s(phx-change="change_per_page")
      assert result =~ ~s(name="per_page")
      for n <- [10, 25, 50, 100], do: assert(result =~ ~s(value="#{n}"))
      assert result =~ ~r/value="25"\s+selected/
      refute result =~ ~r/value="10"\s+selected/
      refute result =~ ~s(value="auto")
      refute result =~ "phx-hook"
    end

    test "custom options and event name" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.page_size_selector value={20} options={[20, 40]} on_change="resize" />
        """)

      assert result =~ ~s(phx-change="resize")
      assert result =~ ~s(value="20")
      assert result =~ ~s(value="40")
      refute result =~ ~s(value="25")
    end

    # A page size the LiveView allows but the caller's option list omits must
    # still be shown — otherwise the select would render blank.
    test "a value outside the options is appended in order" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.page_size_selector value={30} options={[10, 50]} />
        """)

      assert result =~ ~r/value="10".*value="30"\s+selected.*value="50"/s
    end

    test "auto_fit renders the Auto option and the PageSizeAutoFit hook" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.page_size_selector id="pp" value={10} auto_fit auto table_id="users-table" />
        """)

      assert result =~ ~s(phx-hook="PageSizeAutoFit")
      assert result =~ ~s(data-auto="true")
      assert result =~ ~s(data-table-id="users-table")
      assert result =~ ~s(data-options="10,25,50,100")
      assert result =~ ~s(data-event="change_per_page")
      assert result =~ ~r/value="auto"\s+selected/
      # Auto wins the selection over the numeric value it resolved to.
      refute result =~ ~r/value="10"\s+selected/
    end

    test "auto_fit without table_id raises" do
      assigns = %{}

      assert_raise ArgumentError, ~r/requires `table_id`/, fn ->
        rendered_to_string(~H"""
        <.page_size_selector value={10} auto_fit />
        """)
      end
    end
  end
end
