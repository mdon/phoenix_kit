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

  test "label survives a :description slot (regression: blank labels)" do
    # HEEx hands the component BODY to the default slot even when that body
    # contains nothing but named-slot tags and whitespace. The old either/or
    # guard (`if @inner_block != []`) then rendered that whitespace INSTEAD of
    # the label, blanking every label= + <:description> checkbox app-wide.
    assigns = %{}

    html =
      render(~H"""
      <.checkbox name="opt" checked={false} label="Enabled">
        <:description>Disabled profiles are never used.</:description>
      </.checkbox>
      """)

    assert html =~ "Enabled"
    assert html =~ "Disabled profiles are never used."
  end

  test "rich default-slot content renders alongside (not instead of) the label" do
    assigns = %{}

    html =
      render(~H"""
      <.checkbox name="opt" checked={false} label="Allow login">
        Connects the contact to a user account.
      </.checkbox>
      """)

    assert html =~ "Allow login"
    assert html =~ "Connects the contact to a user account."
  end

  test "a slot-only checkbox (no label attr) still renders its content" do
    assigns = %{}

    html =
      render(~H"""
      <.checkbox name="opt" checked={false}>
        <span class="badge">Rich label</span>
      </.checkbox>
      """)

    assert html =~ "Rich label"
  end
end
