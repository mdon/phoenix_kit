defmodule PhoenixKitWeb.Components.Core.FormFieldLabelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.Core.FormFieldLabel

  # 2026-08-31: Select/Textarea labels (through this component) must
  # match <.input>'s inline label — a plain font-semibold span, NOT
  # daisyUI's fieldset-legend, whose smaller/muted styling made a select
  # label visibly differ from the input labels beside it in one grid
  # (the "Unit looks different from the fields around it" report).
  test "renders the plain font-semibold span Input uses, not fieldset-legend" do
    html =
      render_component(&FormFieldLabel.label/1,
        for: "some-input",
        class: "block mb-2",
        inner_block: [%{inner_block: fn _, _ -> "Unit" end}]
      )

    assert html =~ ~s(for="some-input")
    assert html =~ "font-semibold"
    assert html =~ "Unit"
    refute html =~ "fieldset-legend"
  end
end
