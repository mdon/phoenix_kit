defmodule PhoenixKitWeb.Components.Core.ChartCrosshairTest do
  @moduledoc """
  `line_chart hover={:crosshair}` — the server half of the crosshair
  readout. Every label the readout shows is computed here; the
  `PkChartCrosshair` hook (test/js/chart_crosshair.test.cjs) only places
  it, so the payload is what these tests read.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.Chart

  defp payload(html) do
    [_, json] = Regex.run(~r/data-points="([^"]*)"/, html)
    json |> unescape() |> Jason.decode!() |> Map.fetch!("points")
  end

  defp rows(html) do
    [_, json] = Regex.run(~r/data-points="([^"]*)"/, html)
    json |> unescape() |> Jason.decode!() |> Map.fetch!("rows")
  end

  defp unescape(text) do
    text
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

  test "no crosshair layer for the native readout" do
    for hover <- [false, true, :native] do
      assigns = %{hover: hover}

      html =
        rendered_to_string(~H"""
        <.line_chart id="c" data={[{0, 1}, {1, 2}]} hover={@hover} />
        """)

      refute html =~ "PkChartCrosshair"
      refute html =~ "data-pk-crosshair"
    end
  end

  test ":native reads the same as true" do
    assigns = %{}

    native =
      rendered_to_string(~H"""
      <.line_chart id="c" data={[{0, 1}, {1, 2}]} hover={:native} />
      """)

    plain =
      rendered_to_string(~H"""
      <.line_chart id="c" data={[{0, 1}, {1, 2}]} hover />
      """)

    assert native == plain
  end

  test "the layer carries the hook, and the native bands stay as the no-JS readout" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.line_chart id="price" data={[{0, 1}, {1, 2}]} hover={:crosshair} />
      """)

    assert html =~ ~s(id="price-crosshair")
    assert html =~ ~s(phx-hook="PkChartCrosshair")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ ~s(data-pk-crosshair="true")
    assert html =~ ~s(tabindex="0")
    assert html =~ ~s(aria-live="polite")
    assert html =~ "<title>1</title>"
  end

  test "step slots: bands, snap position and formatted labels, in percent of the box" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.line_chart
        id="c"
        data={[{360, 10}, {720, 30}, {1080, 20}]}
        x_domain={{0, 1440}}
        y_domain={{0, 40}}
        step
        hover={:crosshair}
        x_format={&"#{div(&1, 60)}:00"}
        value_format={&"€#{&1}"}
        width={1440}
        height={400}
      />
      """)

    assert [
             [25.0, 50.0, 25.0, 75.0, "6:00", "€10", nil, []],
             [50.0, 75.0, 50.0, 25.0, "12:00", "€30", nil, []],
             [75.0, 100.0, 75.0, 50.0, "18:00", "€20", nil, []]
           ] = payload(html)
  end

  test "no x_format: no x line; y_invert moves the dot, not the label" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.line_chart id="c" data={[{0, 1}, {1, 3}]} y_domain={{0, 4}} y_invert hover={:crosshair} />
      """)

    assert [[_, _, +0.0, 25.0, nil, "1", nil, []], [_, _, 100.0, 75.0, nil, "3", nil, []]] =
             payload(html)
  end

  test "point_note gets x, y, index, the ascending rank and the count; ties share a place" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.line_chart
        id="c"
        data={[{0, 5}, {1, 2}, {2, 5}, {3, 9}]}
        hover={:crosshair}
        point_note={&"#{&1.rank} of #{&1.count} (#{&1.index}@#{&1.x})"}
      />
      """)

    assert payload(html) |> Enum.map(&Enum.at(&1, 6)) ==
             ["2 of 4 (0@0)", "1 of 4 (1@1)", "2 of 4 (2@2)", "4 of 4 (3@3)"]
  end

  test "a point_note that raises, or returns nil, shows no note rather than breaking the chart" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.line_chart
        id="c"
        data={[{0, 5}, {1, 2}]}
        hover={:crosshair}
        point_note={fn _ -> raise "x" end}
      />
      """)

    assert payload(html) |> Enum.map(&Enum.at(&1, 6)) == [nil, nil]

    html =
      rendered_to_string(~H"""
      <.line_chart id="c" data={[{0, 5}, {1, 2}]} hover={:crosshair} point_note={fn _ -> nil end} />
      """)

    assert payload(html) |> Enum.map(&Enum.at(&1, 6)) == [nil, nil]
  end

  # The last step of a series with no `x_domain` holds for no stretch of x
  # (it ends where the domain does), so it has no band — here the datum at 5.
  test "rows active at each x, right-open, in the order given" do
    assigns = %{
      rows: [
        %{label: "Boiler", color: "#f59e0b", bands: [{0, 2}]},
        %{
          "label" => "Car",
          "color" => "var(--color-info)",
          "bands" => [[1, 3], %{from: 5, to: 6}]
        },
        %{label: "Idle", bands: []}
      ]
    }

    html =
      rendered_to_string(~H"""
      <.line_chart id="c" data={[{0, 1}, {1, 1}, {2, 1}, {5, 1}]} step hover={:crosshair} rows={@rows} />
      """)

    assert rows(html) == [["Boiler", "#f59e0b"], ["Car", "var(--color-info)"], ["Idle", nil]]
    assert payload(html) |> Enum.map(&Enum.at(&1, 7)) == [[0], [0, 1], [1]]
  end

  test "a colour that is not a colour is dropped; malformed rows and bands are skipped" do
    assigns = %{
      rows: [
        %{label: "Bad", color: "red; background: url(x)", bands: [{0, 5}, :nope, {"a", 3}]},
        %{color: "#fff", bands: [{0, 5}]},
        "not a row"
      ]
    }

    html =
      rendered_to_string(~H"""
      <.line_chart id="c" data={[{0, 1}, {1, 1}]} hover={:crosshair} rows={@rows} />
      """)

    assert rows(html) == [["Bad", nil]]
    assert payload(html) |> Enum.map(&Enum.at(&1, 7)) == [[0], [0]]
  end

  test "labels are escaped in the attribute" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.line_chart id="c" data={[{0, 1}]} hover={:crosshair} value_format={fn _ -> ~s(<b>"x"</b>) end} />
      """)

    refute html =~ "<b>"
    assert [[_, _, _, _, _, ~s(<b>"x"</b>), _, _]] = payload(html)
  end

  test "no data: no layer, the empty slot" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.line_chart id="c" data={[]} hover={:crosshair}>
        <:empty>Nothing yet</:empty>
      </.line_chart>
      """)

    refute html =~ "PkChartCrosshair"
    assert html =~ "Nothing yet"
  end
end
