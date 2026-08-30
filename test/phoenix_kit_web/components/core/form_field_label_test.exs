defmodule PhoenixKitWeb.Components.Core.FormFieldLabelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.Core.FormFieldLabel
  alias PhoenixKitWeb.Components.Core.Input

  defp label_html(opts) do
    render_component(
      &FormFieldLabel.label/1,
      Keyword.merge(
        [for: "some-input", inner_block: [%{inner_block: fn _, _ -> "Unit" end}]],
        opts
      )
    )
  end

  # 2026-08-31: Select/Textarea labels (through this component) must match
  # <.input>'s inline label. `fieldset-legend` is daisyUI's hook for a legend
  # in a real `.fieldset`; borrowed inside `.label` it set
  # `color: var(--color-base-content)` and `padding-block: 0.5rem`, so a
  # select label rendered darker and taller than the input labels beside it
  # in one grid (the "Unit looks different from the fields around it" report).
  test "renders the plain font-semibold span Input uses, not fieldset-legend" do
    html = label_html(class: "block")

    assert html =~ ~s(for="some-input")
    assert html =~ "font-semibold"
    assert html =~ "Unit"
    refute html =~ "fieldset-legend"
  end

  test "the caller's class survives alongside the base classes" do
    html = label_html(class: "block")

    assert html =~ "label"
    assert html =~ "block"
  end

  # The bug this component keeps re-acquiring is a *size* one, and every
  # variant of it is spelled with a text-* utility. Assert the span carries
  # none: a bare `=~ "font-semibold"` passes just as happily with `text-xs`
  # appended, which is exactly the regression.
  test "the label span carries no font-size utility of its own" do
    html = label_html([])

    refute html =~ ~r/<span class="[^"]*\btext-(xs|sm|base|lg|xl)\b/
  end

  # The strongest pin available: render both and compare the spans. If either
  # component's label markup drifts, this fails and names the drift.
  test "the label span is byte-identical to the one <.input> renders" do
    ours = label_html([]) |> label_span()

    theirs =
      render_component(&Input.input/1,
        id: "x",
        name: "x",
        label: "Unit",
        type: "text",
        value: "",
        errors: []
      )
      |> label_span()

    assert ours == theirs
  end

  test "required renders the marker as a sibling span, as Input does" do
    html = label_html(required: true)

    assert html =~ ~s(<span class="text-error ml-0.5" aria-hidden="true">*</span>)
    # Outside the font-semibold span — a bold asterisk is Input's marker in
    # the wrong weight.
    refute html =~ ~r/<span class="font-semibold">[^<]*<span class="text-error/
  end

  defp label_span(html) do
    case Regex.run(~r/<span class="font-semibold"[^>]*>/, html) do
      [tag] -> tag
      nil -> flunk("no font-semibold label span in:\n#{html}")
    end
  end
end
