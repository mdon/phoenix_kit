defmodule PhoenixKitWeb.Components.Core.FormSectionActionsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.Core.FormActions
  import PhoenixKitWeb.Components.Core.FormSection

  describe "form_section :actions" do
    test "renders the actions in the title row, after the title" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.form_section title="Timeline">
          <:actions><button id="reset">Reset</button></:actions>
          <p>body</p>
        </.form_section>
        """)

      {title, _} = :binary.match(html, "Timeline")
      {reset, _} = :binary.match(html, ~s(id="reset"))
      {body, _} = :binary.match(html, "<p>body</p>")

      assert title < reset
      assert reset < body
    end

    test "without actions the title renders once, as before" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.form_section title="Plain">
          <p>body</p>
        </.form_section>
        """)

      assert length(:binary.matches(html, "card-title")) == 1
      refute html =~ "justify-between"
    end
  end

  describe "form_actions submit_disabled" do
    test "disables only the submit button" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.form_actions cancel_to="/back" submit_label="Waiting for uploads…" submit_disabled />
        """)

      assert html =~ ~r/<button[^>]*type="submit"[^>]*disabled/
      refute html =~ ~r/<a[^>]*disabled/
    end

    test "leaves the submit button enabled by default" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.form_actions cancel_to="/back" submit_label="Save" />
        """)

      refute html =~ ~r/<button[^>]*type="submit"[^>]*disabled/
    end
  end
end
