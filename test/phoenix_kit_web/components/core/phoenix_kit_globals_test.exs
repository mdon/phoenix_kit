defmodule PhoenixKitWeb.Components.Core.PhoenixKitGlobalsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.Core.PhoenixKitGlobals

  test "lifts form controls to 16px on phones, only inside the kit's markup" do
    assigns = %{}
    html = rendered_to_string(~H"<.phoenix_kit_globals />")

    assert html =~ "data-pk-mobile-inputs"
    assert html =~ "@media (pointer: coarse) and (max-width: 767px)"
    assert html =~ ":is(#admin-drawer, [data-phoenix-kit])"
    assert html =~ "font-size: max(16px, 1em)"
  end
end
