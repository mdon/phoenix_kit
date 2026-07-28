defmodule PhoenixKitWeb.Components.Core.StatCardTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.StatCard

  defp render(template), do: rendered_to_string(template)

  defp card(assigns) do
    ~H"""
    <.stat_card value="42" title="Users" subtitle="Total" value_color={@color} compact={@compact}>
      <:icon>i</:icon>
    </.stat_card>
    """
  end

  test "no value_color leaves the value unstyled" do
    for compact <- [true, false] do
      assigns = %{color: nil, compact: compact}
      refute render(card(assigns)) =~ "style="
    end
  end

  test "a colour is applied in both layouts" do
    for compact <- [true, false] do
      assigns = %{color: "hsl(140 85% 55%)", compact: compact}
      assert render(card(assigns)) =~ "color: hsl(140 85% 55%)"
    end
  end

  test "modern colour syntaxes survive intact" do
    for color <- [
          "var(--brand)",
          "oklch(0.7 0.1 250)",
          "color-mix(in srgb, red, blue)",
          "#ff0000"
        ] do
      assigns = %{color: color, compact: false}
      assert render(card(assigns)) =~ "color: #{color}"
    end
  end

  test "a semicolon cannot append a second declaration" do
    # These values are typically computed from data; one stray `;` would
    # otherwise let the value write arbitrary CSS onto the element.
    assigns = %{color: "red; background: url(http://evil.example/x)", compact: false}
    html = render(card(assigns))

    [_, style] = Regex.run(~r/style="([^"]*)"/, html)

    # One declaration only. What remains is a single malformed `color` value,
    # which the browser discards outright — the injected property never
    # applies and its url() is never fetched.
    refute style =~ ";", "the style attribute must not contain a second declaration"
    assert String.starts_with?(style, "color: ")
  end

  test "a quote cannot break out of the style attribute" do
    hostile = "red\" onmouseover=\"alert(1)"
    assigns = %{color: hostile, compact: false}
    html = render(card(assigns))

    # The payload survives as escaped TEXT inside the style value; what must
    # not happen is it becoming a real attribute. A leading space before the
    # name is what would distinguish an actual breakout.
    # The style attribute must remain ONE well-formed attribute whose value
    # contains no raw quote — that is what a breakout would need.
    [_, style] = Regex.run(~r/style="([^"]*)"/, html)
    refute style =~ ~s("), "raw quote inside the style value would end the attribute early"
    assert html =~ "&quot;", "the quote must be escaped, not emitted raw"
  end

  test "a blank colour renders no style attribute" do
    assigns = %{color: "   ", compact: false}
    refute render(card(assigns)) =~ "style="
  end

  test "the rounded attr is applied, as a literal class" do
    # It was declared and documented for a long time while the class was
    # hardcoded. The mapping must emit literal class names: Tailwind scans
    # SOURCE, so an interpolated `rounded-#{token}` produces markup whose CSS
    # was never generated.
    assigns = %{color: nil, compact: false}

    default =
      render(~H"""
      <.stat_card value="1" title="t" subtitle="s">
        <:icon>i</:icon>
      </.stat_card>
      """)

    assert default =~ "rounded-box"

    custom =
      render(~H"""
      <.stat_card value="1" title="t" subtitle="s" rounded="full">
        <:icon>i</:icon>
      </.stat_card>
      """)

    assert custom =~ "rounded-full"
    refute custom =~ "rounded-box shadow"
  end
end
