defmodule PhoenixKitWeb.Components.Core.DecimalInputTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2, to_form: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.DecimalInput

  defp render(template), do: rendered_to_string(template)

  defp input_tag(html) do
    [tag] = Regex.run(~r/<input[^>]*name="[^"]*"[^>]*>/, html)
    tag
  end

  test "renders a text control with a decimal keyboard, never a number spinner" do
    assigns = %{}

    tag =
      render(~H"""
      <.decimal_input id="qty" name="qty" value={Decimal.new("2.50")} />
      """)
      |> input_tag()

    assert tag =~ ~s(type="text")
    assert tag =~ ~s(inputmode="decimal")
    assert tag =~ ~s(autocomplete="off")
    assert tag =~ ~s(value="2.5")
    refute tag =~ "step="
    refute tag =~ ~s(type="number")
  end

  test "a bound field supplies name, id, value and errors" do
    changeset =
      {%{}, %{qty: :decimal}}
      |> Ecto.Changeset.cast(%{"qty" => "abc"}, [:qty])
      |> Map.put(:action, :validate)

    assigns = %{form: to_form(changeset, as: "row")}

    html =
      render(~H"""
      <.decimal_input field={@form[:qty]} label="Quantity" />
      """)

    assert html =~ ~s(name="row[qty]")
    assert html =~ ~s(id="row_qty")
    assert html =~ ~s(value="abc")
    assert html =~ "Quantity"
    assert html =~ "input-error"
    assert html =~ "is invalid"
  end

  test "the raw text a user typed is echoed back unchanged, so a comma survives a round trip" do
    assigns = %{}

    tag =
      render(~H"""
      <.decimal_input id="qty" name="qty" value="2,5" />
      """)
      |> input_tag()

    assert tag =~ ~s(value="2,5")
  end

  test "numbers and decimals are shown normalized" do
    assigns = %{}

    html =
      render(~H"""
      <.decimal_input id="a" name="a" value={Decimal.new("1E+3")} />
      <.decimal_input id="b" name="b" value={2} />
      <.decimal_input id="c" name="c" value={nil} />
      """)

    assert html =~ ~s(value="1000")
    assert html =~ ~s(value="2")
    assert html =~ ~s(name="c" id="c" value="")
  end

  test "a unit suffix renders inside the field" do
    assigns = %{}

    html =
      render(~H"""
      <.decimal_input id="qty" name="qty" value={1} unit="kg" />
      """)

    assert html =~ ~s(<label class="input)
    assert html =~ "kg"
    assert html =~ ~s(aria-hidden="true")
  end

  test "class, wrapper_class, placeholder and phx attributes pass through" do
    assigns = %{}

    html =
      render(~H"""
      <.decimal_input
        id="qty"
        name="qty"
        value={1}
        class="input-sm text-right"
        wrapper_class="w-24"
        placeholder="0"
        phx-debounce="400"
        phx-blur="commit"
      />
      """)

    assert html =~ ~s(class="w-24")
    assert html =~ "input-sm text-right"
    assert html =~ ~s(placeholder="0")
    assert html =~ ~s(phx-debounce="400")
    assert html =~ ~s(phx-blur="commit")
  end

  test "required renders the marker next to the label" do
    assigns = %{}

    html =
      render(~H"""
      <.decimal_input id="qty" name="qty" value={1} label="Qty" required />
      """)

    assert html =~ "text-error"
    assert html =~ ~s(required)
  end

  test "a zero empties itself on focus and comes back when the field is left empty" do
    assigns = %{}

    tag =
      render(~H"""
      <.decimal_input id="qty" name="qty" value={Decimal.new("0")} />
      """)
      |> input_tag()

    # the attribute value is HTML-escaped in the markup (' → &#39;)
    attr = fn name ->
      [js] = Regex.run(~r/#{name}="([^"]*)"/, tag, capture: :all_but_first)
      String.replace(js, "&#39;", "'")
    end

    onfocus = attr.("onfocus")
    onblur = attr.("onblur")

    # focus: only a zero-like text is cleared, and it is remembered
    assert onfocus =~ "this.dataset.pkZero=this.value"
    assert onfocus =~ "this.value=''"
    [regex] = Regex.run(~r{^if\(/(.*)/\.test}, onfocus, capture: :all_but_first)
    js_zero = ~r/#{regex}/

    for zero <- ["0", "0,00", "0.0", " 0 ", "-0", ",0", "00"], do: assert(zero =~ js_zero)
    for other <- ["", "1", "0,5", "10", "2.5", "0x"], do: refute(other =~ js_zero)

    # blur: the remembered zero returns only when nothing was entered
    assert onblur =~ "this.value.trim()===''"
    assert onblur =~ "this.value=this.dataset.pkZero"
    assert onblur =~ "delete this.dataset.pkZero"
  end

  test "the unit variant carries the same focus and blur handlers" do
    assigns = %{}

    tag =
      render(~H"""
      <.decimal_input id="w" name="w" value={Decimal.new("0")} unit="kg" />
      """)
      |> input_tag()

    assert tag =~ ~s(onfocus=")
    assert tag =~ ~s(onblur=")
  end
end
