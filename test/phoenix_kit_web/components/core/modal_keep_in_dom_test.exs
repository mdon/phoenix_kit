defmodule PhoenixKitWeb.Components.Core.ModalKeepInDomTest do
  @moduledoc """
  Render tests for `<.modal>`'s `keep_in_dom` branch — the new mode
  added to support instant client-side open via the `PkDialog` hook.
  Default behaviour (conditional render) is preserved for backwards
  compat.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]

  describe "modal/1 default (keep_in_dom=false)" do
    test "show=false → not rendered at all" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.modal show={false} on_close="close">
          <:title>Hidden</:title>
          inside
        </.modal>
        """)

      refute result =~ "<dialog"
      refute result =~ "Hidden"
      refute result =~ "inside"
    end

    test "show=true → renders dialog with data-show='true'" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.modal show={true} on_close="close">
          <:title>Visible</:title>
          inside
        </.modal>
        """)

      assert result =~ "<dialog"
      assert result =~ ~s(data-show="true")
      assert result =~ "Visible"
      assert result =~ "inside"
    end
  end

  describe "modal/1 with keep_in_dom=true" do
    test "show=false STILL renders the dialog with data-show='false'" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.modal show={false} on_close="close" keep_in_dom>
          <:title>Stays put</:title>
          inside
        </.modal>
        """)

      assert result =~ "<dialog"
      assert result =~ ~s(data-show="false")
      assert result =~ ~s(phx-hook="PkDialog")
      # Inner content still in DOM — that's the whole point.
      assert result =~ "Stays put"
      assert result =~ "inside"
    end

    test "show=true → data-show='true' (same as default branch)" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.modal show={true} on_close="close" keep_in_dom>
          inside
        </.modal>
        """)

      assert result =~ ~s(data-show="true")
      assert result =~ ~s(phx-hook="PkDialog")
    end

    test "close-event attr wires on_close for the hook" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.modal show={false} on_close="my_close" keep_in_dom>
          inside
        </.modal>
        """)

      assert result =~ ~s(data-close-event="my_close")
    end

    test "id is derived from on_close when not explicitly passed" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.modal show={false} on_close="close_reorder_modal" keep_in_dom>
          inside
        </.modal>
        """)

      assert result =~ ~s(id="pk-modal-close_reorder_modal")
    end

    test "explicit id overrides the derived id" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.modal id="my-dialog" show={false} on_close="x" keep_in_dom>
          inside
        </.modal>
        """)

      assert result =~ ~s(id="my-dialog")
      refute result =~ ~s(id="pk-modal-x")
    end

    test "closeable=false flips the data attr" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.modal show={true} on_close="x" closeable={false}>
          inside
        </.modal>
        """)

      assert result =~ ~s(data-closeable="false")
    end
  end
end
