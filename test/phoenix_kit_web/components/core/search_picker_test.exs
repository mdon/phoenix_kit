defmodule PhoenixKitWeb.Components.Core.SearchPickerTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.SearchPicker

  defp render(template), do: rendered_to_string(template)

  test "renders the hook input + a hidden client-owned dropdown" do
    assigns = %{}

    html =
      render(~H"""
      <.search_picker id="party-search" dropdown_id="party-dropdown" />
      """)

    assert html =~ ~s(phx-hook="SearchPicker")
    assert html =~ ~s(id="party-search")
    assert html =~ ~s(autocomplete="off")
    # the dropdown is rendered/toggled entirely by the hook — LV must not
    # touch it, and it starts hidden (no server round-trip to open)
    assert html =~ ~s(id="party-dropdown")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ "hidden absolute"
    # default direction: opens downward
    assert html =~ "top-full mt-1"
  end

  test "direction=up floats the dropdown above the input (bottom-of-modal fields)" do
    assigns = %{}

    html =
      render(~H"""
      <.search_picker id="p" dropdown_id="d" direction="up" />
      """)

    assert html =~ "bottom-full mb-1"
    refute html =~ "top-full"
  end

  test "default event names cover the full multi-select contract" do
    assigns = %{}

    html =
      render(~H"""
      <.search_picker id="p" dropdown_id="d" />
      """)

    assert html =~ ~s(data-search-event="picker_search")
    assert html =~ ~s(data-results-event="picker_results")
    assert html =~ ~s(data-pick-event="picker_pick")
    assert html =~ ~s(data-staged-event="picker_staged")
    assert html =~ ~s(data-mode="multi")
    # no free-text row unless the consumer opts in with text_event
    refute html =~ "data-text-event"
  end

  test "event names, target selector, and free-text opt-in are overridable" do
    assigns = %{}

    html =
      render(~H"""
      <.search_picker
        id="p"
        dropdown_id="d"
        target="#my-component"
        search_event="search_party"
        results_event="crm_party_results"
        pick_event="stage_party"
        text_event="stage_text"
        staged_event="crm_party_staged"
      />
      """)

    assert html =~ ~s(data-target="#my-component")
    assert html =~ ~s(data-search-event="search_party")
    assert html =~ ~s(data-results-event="crm_party_results")
    assert html =~ ~s(data-pick-event="stage_party")
    assert html =~ ~s(data-text-event="stage_text")
    assert html =~ ~s(data-staged-event="crm_party_staged")
  end

  test "single mode wires the input as a form field" do
    assigns = %{}

    html =
      render(~H"""
      <.search_picker
        id="loc"
        dropdown_id="loc-dd"
        mode="single"
        name="event[location]"
        value="HQ"
        data-search-on-focus
        phx-debounce="300"
      />
      """)

    assert html =~ ~s(data-mode="single")
    assert html =~ ~s(name="event[location]")
    assert html =~ ~s(value="HQ")
    # global attrs pass through for search-on-focus + LV form debounce
    assert html =~ "data-search-on-focus"
    assert html =~ ~s(phx-debounce="300")
  end

  test "translated labels reach the hook as data attributes" do
    assigns = %{}

    html =
      render(~H"""
      <.search_picker
        id="p"
        dropdown_id="d"
        searching_label="Otsin…"
        add_prefix_label="Lisa"
        add_suffix_label="tekstina"
        adding_label="Lisan…"
        more_label="Veel"
        loading_more_label="Laen…"
      />
      """)

    assert html =~ ~s(data-t-searching="Otsin…")
    assert html =~ ~s(data-t-add-prefix="Lisa")
    assert html =~ ~s(data-t-add-suffix="tekstina")
    assert html =~ ~s(data-t-adding="Lisan…")
    assert html =~ ~s(data-t-more="Veel")
    assert html =~ ~s(data-t-loading-more="Laen…")
  end
end
