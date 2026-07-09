defmodule PhoenixKitWeb.Components.Core.CheckboxTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2, to_form: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.Checkbox

  defp render(template), do: rendered_to_string(template)

  defp form(values), do: to_form(values, as: "event")

  test "a field-bound checkbox derives checked from the field's value" do
    # Regression: `attr :checked, default: false` used to materialize into
    # assigns before the field clause ran, so assign_new never derived from
    # the field and a truthy value STILL rendered unchecked — the classic
    # "toggling visually unchecks itself on the next patch" symptom.
    assigns = %{form: form(%{"all_day" => "true"})}

    html =
      render(~H"""
      <.checkbox field={@form[:all_day]} label="All day" />
      """)

    assert html =~ ~s(type="checkbox")
    assert html =~ "checked"

    assigns = %{form: form(%{"all_day" => "false"})}

    html =
      render(~H"""
      <.checkbox field={@form[:all_day]} label="All day" />
      """)

    refute html =~ ~s(<input type="checkbox" checked)
    refute html =~ ~s(checked="checked")
  end

  test "an explicit checked= overrides the field's value" do
    assigns = %{form: form(%{"all_day" => "true"})}

    html =
      render(~H"""
      <.checkbox field={@form[:all_day]} checked={false} label="All day" />
      """)

    refute html =~ ~s(checked="checked")
  end

  test "a raw (non-field) checkbox still renders without passing checked" do
    assigns = %{}

    html =
      render(~H"""
      <.checkbox name="agree" label="Agree" />
      """)

    assert html =~ ~s(name="agree")
    refute html =~ ~s(checked="checked")
  end
end
