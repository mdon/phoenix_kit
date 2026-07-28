defmodule PhoenixKitWeb.Components.Core.ChartTest do
  @moduledoc """
  These charts are server-rendered SVG, so the rendered markup IS the
  output — geometry bugs are assertable without a browser.

  The invariants worth protecting: never crash on the shapes real data
  actually takes (empty, one point, flat, negative, huge), and never emit
  SVG a browser will silently drop (negative `height`, `NaN` coordinates).
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.Chart

  # ~H expands where it is written and needs an `assigns` variable in scope.
  # These components take no assigns of their own, so each test binds an empty
  # map.
  defp render(template), do: rendered_to_string(template)

  # Every numeric attribute a browser parses. A stray NaN/Infinity makes the
  # whole element vanish, so scan the actual attribute values rather than
  # eyeballing the path string.
  defp numeric_attrs(html) do
    # The leading space matters: without it `viewBox="0 0 960 240"` matches as
    # `x="..."`, because "viewBox" ends in an x.
    ~r/\s(?:x|y|x1|y1|x2|y2|width|height|rx)="([^"]*)"/
    |> Regex.scan(html)
    |> Enum.map(&List.last/1)
  end

  defp path_numbers(html) do
    ~r/[ML]([-\d.eE+]+),([-\d.eE+]+)/
    |> Regex.scan(html)
    |> Enum.flat_map(fn [_, x, y] -> [x, y] end)
  end

  # The `d` of the path that actually carries the stroke — the area fill path
  # always contains an L (it closes to the baseline), so matching on any path
  # would pass even when the line is a bare moveto that paints nothing.
  defp stroked_path(html) do
    case Regex.run(~r/<path[^>]*\sd="([^"]*)"[^>]*stroke="currentColor"/, html) do
      [_, d] -> d
      _ -> ""
    end
  end

  # Coordinates far outside the viewBox mean the chart is invisible even though
  # the numbers are technically finite.
  defp assert_within_viewbox(html, width, height) do
    limit = max(width, height) * 10

    for value <- path_numbers(html) do
      {n, ""} = Float.parse(value)

      assert abs(n) <= limit,
             "coordinate #{n} is far outside the #{width}x#{height} viewBox"
    end
  end

  defp assert_finite_numbers(html) do
    for value <- numeric_attrs(html) ++ path_numbers(html) do
      refute value =~ ~r/nan|inf/i, "non-finite number in rendered SVG: #{inspect(value)}"

      case Float.parse(value) do
        {_, ""} -> :ok
        _ -> flunk("unparseable number in rendered SVG: #{inspect(value)}")
      end
    end
  end

  describe "line_chart/1" do
    test "renders a line path for a simple series" do
      assigns = %{}

      html = render(~H|<.line_chart id="c" data={[{0, 1}, {1, 5}, {2, 3}]} />|)

      assert html =~ "<svg"
      assert html =~ ~s(stroke="currentColor")
      assert stroked_path(html) =~ ~r/^M[\d.]+,[\d.]+ L/
      assert_finite_numbers(html)
    end

    test "empty data renders the :empty slot and no svg" do
      assigns = %{}

      html =
        render(~H"""
        <.line_chart id="c" data={[]}>
          <:empty>Nothing to show</:empty>
        </.line_chart>
        """)

      assert html =~ "Nothing to show"
      refute html =~ "<svg"
    end

    test "empty data without an :empty slot renders nothing rather than crashing" do
      assigns = %{}

      html = render(~H|<.line_chart id="c" data={[]} />|)

      refute html =~ "<svg"
    end

    test "a single point does not crash and still draws something visible" do
      assigns = %{}

      # A lone "M x,y" is a valid path that paints NOTHING. Interval data of
      # length one is a real case (first slot of the day), so it has to
      # produce a visible mark.
      html = render(~H|<.line_chart id="c" data={[{5, 10}]} />|)

      assert html =~ "<svg"
      assert_finite_numbers(html)

      assert stroked_path(html) =~ ~r/^M[\d.]+,[\d.]+ L/,
             "a lone moveto paints nothing; a single point must still draw a segment"
    end

    test "negative values render finite geometry" do
      assigns = %{}

      # Electricity prices go negative; this must not produce NaN or invert.
      html = render(~H|<.line_chart id="c" data={[{0, -40}, {1, -10}, {2, 25}]} />|)

      assert_finite_numbers(html)
    end

    test "a completely flat series renders finite geometry" do
      assigns = %{}

      html = render(~H|<.line_chart id="c" data={[{0, 7}, {1, 7}, {2, 7}]} />|)

      assert_finite_numbers(html)
    end

    test "an explicit zero-span y_domain does not divide by zero" do
      assigns = %{}

      html = render(~H|<.line_chart id="c" data={[{0, 5}, {1, 5}]} y_domain={{5, 5}} />|)

      assert_finite_numbers(html)
    end

    test "step mode holds each y until the next x" do
      assigns = %{}

      html =
        render(~H|<.line_chart id="c" data={[{0, 0}, {10, 100}]} step y_domain={{0, 100}} />|)

      # Two points become four in step mode: hold, then jump.
      assert length(path_numbers(html)) >= 8
      assert_finite_numbers(html)
    end

    test "step mode extends the final slot to the x domain's right edge" do
      assigns = %{}

      html =
        render(
          ~H|<.line_chart id="c" data={[{0, 1}, {5, 2}]} step x_domain={{0, 10}} width={100} />|
        )

      # The last slot must reach the domain edge (x=100 in viewBox units),
      # not stop at the last data x (x=50).
      assert html =~ ~r/L100(?:\.0)?,/
      assert_finite_numbers(html)
    end

    test "marker_x inside the domain renders a dashed marker" do
      assigns = %{}

      html = render(~H|<.line_chart id="c" data={[{0, 1}, {10, 2}]} marker_x={5} />|)

      assert html =~ ~s(stroke-dasharray="4 4")
    end

    test "marker_x outside the domain is omitted" do
      assigns = %{}

      html = render(~H|<.line_chart id="c" data={[{0, 1}, {10, 2}]} marker_x={99} />|)

      refute html =~ ~s(stroke-dasharray="4 4")
    end

    test "gridlines={0} disables gridlines" do
      assigns = %{}

      html = render(~H|<.line_chart id="c" data={[{0, 1}, {1, 2}]} gridlines={0} />|)

      refute html =~ ~s(stroke-opacity="0.08")
    end

    test "area={false} omits the filled path" do
      assigns = %{}

      html = render(~H|<.line_chart id="c" data={[{0, 1}, {1, 2}]} area={false} />|)

      refute html =~ "url(#c-fill)"
    end

    test "the gradient id is namespaced by the component id" do
      assigns = %{}

      # Two charts on one page must not share a gradient def.
      html = render(~H|<.line_chart id="left" data={[{0, 1}, {1, 2}]} />|)

      assert html =~ ~s(id="left-fill")
      assert html =~ "url(#left-fill)"
    end

    test "float data renders finite geometry" do
      assigns = %{}

      html = render(~H|<.line_chart id="c" data={[{0.0, 1.5}, {1.25, 2.75}]} />|)

      assert_finite_numbers(html)
    end

    test "a reversed x_domain is normalised rather than exploding off-canvas" do
      assigns = %{}
      # {10, 0} used to drive the span negative; the 1.0e-9 floor then produced
      # coordinates around 1.0e12 and the chart simply vanished.
      html = render(~H|<.line_chart id="c" data={[{0, 1}, {10, 2}]} x_domain={{10, 0}} />|)

      assert_finite_numbers(html)
      assert_within_viewbox(html, 960, 240)
    end

    test "a reversed y_domain is normalised rather than exploding off-canvas" do
      assigns = %{}
      html = render(~H|<.line_chart id="c" data={[{0, 1}, {10, 2}]} y_domain={{5, 0}} />|)

      assert_finite_numbers(html)
      assert_within_viewbox(html, 960, 240)
    end

    test "unsorted data is drawn left-to-right" do
      assigns = %{}
      # Unsorted input rendered as a zigzag that reads like a chart bug.
      html = render(~H|<.line_chart id="c" data={[{5, 1}, {0, 9}, {10, 2}]} />|)

      xs =
        stroked_path(html)
        |> then(&Regex.scan(~r/[ML]([-\d.eE+]+),/, &1))
        |> Enum.map(fn [_, x] -> elem(Float.parse(x), 0) end)

      assert xs == Enum.sort(xs), "points must be drawn in ascending x order, got: #{inspect(xs)}"
    end

    test "carries an accessible name" do
      assigns = %{}

      html = render(~H|<.line_chart id="c" data={[{0, 1}, {1, 2}]} aria_label="Prices today" />|)

      # role="img" without a name is an unlabelled graphic to a screen reader.
      assert html =~ "Prices today"
    end
  end

  describe "data normalisation" do
    test "one bad point never takes the page down" do
      # A library primitive that raises mid-render kills the whole LiveView.
      # Ecto hands callers Decimals; JSON hands them nils and strings.
      assigns = %{}

      for bad <- [nil, "12", :atom, %{}] do
        assigns = Map.put(assigns, :bad, bad)

        html =
          render(~H|<.line_chart id="c" data={[{0, 1}, {1, @bad}, {2, 3}]} />|)

        assert html =~ "<svg"
        assert_finite_numbers(html)
      end
    end

    test "Decimal values are plotted, not crashed on" do
      assigns = %{
        data: [{0, Decimal.new("1.5")}, {1, Decimal.new("2.75")}, {Decimal.new("2"), 3}]
      }

      html = render(~H|<.line_chart id="c" data={@data} />|)

      assert html =~ "<svg"
      assert_finite_numbers(html)
    end

    test "points may be maps as well as tuples" do
      assigns = %{data: [%{x: 0, y: 1}, %{x: 1, y: 5}]}

      html = render(~H|<.line_chart id="c" data={@data} />|)

      assert html =~ "<svg"
      assert_finite_numbers(html)
    end

    test "string-keyed maps work too" do
      assigns = %{data: [%{"x" => 0, "y" => 1}, %{"x" => 1, "y" => 5}]}

      assert render(~H|<.line_chart id="c" data={@data} />|) =~ "<svg"
    end

    test "when nothing is usable the :empty slot renders" do
      assigns = %{}

      html =
        render(~H"""
        <.line_chart id="c" data={[{nil, nil}, {"a", "b"}]}>
          <:empty>No usable data</:empty>
        </.line_chart>
        """)

      assert html =~ "No usable data"
      refute html =~ "<svg"
    end

    test "bar data missing :value is dropped rather than raising" do
      assigns = %{data: [%{label: "a"}, %{label: "b", value: 5}]}

      html = render(~H|<.bar_chart id="b" data={@data} />|)

      assert length(Regex.scan(~r/<rect/, html)) == 1
    end

    test "a non-numeric marker_x is ignored" do
      assigns = %{}
      html = render(~H|<.line_chart id="c" data={[{0, 1}, {10, 2}]} marker_x="noon" />|)

      refute html =~ ~s(stroke-dasharray="4 4")
    end
  end

  describe "bar_chart extras" do
    test "each bar carries a native title tooltip" do
      assigns = %{}

      html =
        render(~H|<.bar_chart id="b" data={[%{label: "Mon", value: 12}]} />|)

      assert html =~ "<title>Mon: 12</title>"
    end

    test "a per-datum class colours a single bar" do
      assigns = %{data: [%{label: "a", value: 1}, %{label: "b", value: 2, class: "text-error"}]}

      assert render(~H|<.bar_chart id="b" data={@data} />|) =~ "text-error"
    end

    test "the zero baseline is drawn only when the data spans both signs" do
      assigns = %{}

      mixed =
        render(
          ~H|<.bar_chart id="b" data={[%{label: "a", value: -1}, %{label: "b", value: 2}]} />|
        )

      positive =
        render(
          ~H|<.bar_chart id="b" data={[%{label: "a", value: 1}, %{label: "b", value: 2}]} />|
        )

      assert mixed =~ ~s(stroke-opacity="0.25")
      refute positive =~ ~s(stroke-opacity="0.25")
    end

    test "the svg carries the given id" do
      assigns = %{}

      assert render(~H|<.bar_chart id="daily" data={[%{label: "a", value: 1}]} />|) =~
               ~s(id="daily")
    end

    test "labels are sized to their bar's slot, not spread edge-to-edge" do
      # `justify-between` pinned the first and last labels to the container
      # edges while the bars sit at slot centres.
      assigns = %{data: Enum.map(1..3, &%{label: "d#{&1}", value: &1})}

      html = render(~H|<.bar_chart id="b" data={@data} show_labels />|)

      assert html =~ "width: 33.3%"
      refute html =~ "justify-between"
    end
  end

  describe "sparkline/1" do
    test "renders a polyline for a list of values" do
      assigns = %{}

      html = render(~H|<.sparkline values={[1, 5, 2, 8]} />|)

      assert html =~ "<polyline"
      assert_finite_numbers(html)
    end

    test "a single value draws a flat line rather than an empty box" do
      # One sample is a real state; rendering nothing reads as a broken chart.
      assigns = %{}
      html = render(~H|<.sparkline values={[7]} />|)

      assert html =~ "<polyline"
      assert_finite_numbers(html)
    end

    test "no usable values renders the :empty slot" do
      assigns = %{}

      html =
        render(~H"""
        <.sparkline values={[]}>
          <:empty>No trend</:empty>
        </.sparkline>
        """)

      assert html =~ "No trend"
      refute html =~ "<polyline"
    end

    test "identical values render finite geometry" do
      assigns = %{}

      html = render(~H|<.sparkline values={[3, 3, 3]} />|)

      assert_finite_numbers(html)
    end

    test "negative values render finite geometry" do
      assigns = %{}

      html = render(~H|<.sparkline values={[-5, -1, -9]} />|)

      assert_finite_numbers(html)
    end
  end

  describe "bar_chart/1" do
    test "renders one rect per datum" do
      assigns = %{}

      html =
        render(
          ~H|<.bar_chart id="b" data={[%{label: "a", value: 1}, %{label: "b", value: 2}]} />|
        )

      assert length(Regex.scan(~r/<rect/, html)) == 2
      assert_finite_numbers(html)
    end

    test "empty data renders the :empty slot" do
      assigns = %{}

      html =
        render(~H"""
        <.bar_chart id="b" data={[]}>
          <:empty>No bars</:empty>
        </.bar_chart>
        """)

      assert html =~ "No bars"
      refute html =~ "<rect"
    end

    test "negative values never produce a negative rect height" do
      assigns = %{}

      # SVG drops a rect with negative height entirely — the bar silently
      # disappears instead of rendering below a baseline.
      html =
        render(
          ~H|<.bar_chart id="b" data={[%{label: "a", value: -5}, %{label: "b", value: 10}]} />|
        )

      for [_, h] <- Regex.scan(~r/height="([^"]*)"/, html) do
        {value, ""} = Float.parse(h)
        assert value >= 0, "negative rect height would render nothing: #{h}"
      end

      assert_finite_numbers(html)
    end

    test "all-zero values render finite geometry" do
      assigns = %{}

      html =
        render(
          ~H|<.bar_chart id="b" data={[%{label: "a", value: 0}, %{label: "b", value: 0}]} />|
        )

      assert_finite_numbers(html)
    end

    test "all-negative values render finite geometry" do
      assigns = %{}

      html =
        render(
          ~H|<.bar_chart id="b" data={[%{label: "a", value: -3}, %{label: "b", value: -8}]} />|
        )

      assert_finite_numbers(html)
    end

    test "show_labels renders one label per bar" do
      assigns = %{}

      html =
        render(
          ~H|<.bar_chart id="b" data={[%{label: "Mon", value: 1}, %{label: "Tue", value: 2}]} show_labels />|
        )

      assert html =~ "Mon"
      assert html =~ "Tue"
    end
  end
end
