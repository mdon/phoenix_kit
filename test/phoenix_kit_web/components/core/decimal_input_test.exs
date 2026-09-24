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

  test "the default layout renders one control, whether bare is omitted or false" do
    assigns = %{}

    for html <- [
          render(~H"""
          <.decimal_input id="q" name="value" value="0" />
          """),
          render(~H"""
          <.decimal_input id="q" name="value" value="0" unit="kg" />
          """)
        ] do
      assert length(Regex.scan(~r/<input/, html)) == 1
      assert html =~ ~r/\A<div phx-feedback-for="value"/
    end

    assert render(~H"""
           <.decimal_input id="q" name="value" value="0" label="Qty" bare={false} />
           """) ==
             render(~H"""
             <.decimal_input id="q" name="value" value="0" label="Qty" />
             """)
  end

  # The contrast `bare` exists for: the default layouts fill their width
  # (the plain control itself, or the unit variant's <label>), and the
  # unit variant's inner control grows inside that label.
  test "the default layouts keep their own classes on the control and the unit label" do
    assigns = %{}

    plain =
      render(~H"""
      <.decimal_input id="q" name="value" value="1" />
      """)
      |> input_tag()

    assert plain =~ ~s(class="input w-full transition-colors focus:input-primary)

    unit =
      render(~H"""
      <.decimal_input
        id="q"
        name="value"
        value="1"
        unit="kg"
        errors={["is invalid"]}
        placeholder="0"
      />
      """)

    [label] = Regex.run(~r/<label class="input[^"]*"/, unit)
    assert label =~ "w-full"
    assert label =~ "input-error"

    inner = input_tag(unit)
    assert inner =~ ~s(class="grow min-w-0")
    assert inner =~ ~s(placeholder="0")
  end

  describe "bare" do
    # A host that sets the control inside its own group — a daisyUI `join`
    # with a unit button, a table cell — gets the <input> alone: the
    # wrapper <div> would sit between `.join` and its `.join-item`.
    test "renders the control alone: no wrapper, label, unit or error list" do
      assigns = %{}

      html =
        render(~H"""
        <.decimal_input
          bare
          id="q"
          name="value"
          value="0"
          label="Quantity"
          unit="kg"
          errors={["is invalid"]}
          wrapper_class="mb-4"
          class="join-item w-20 text-center"
        />
        """)

      assert html =~ ~r/\A<input [^>]*\/?>\z/
      assert html =~ ~s(id="q")
      refute html =~ "<div"
      refute html =~ "<label"
      refute html =~ "Quantity"
      refute html =~ "kg"
      refute html =~ "is invalid"
      refute html =~ "mb-4"
    end

    test "keeps what makes it a decimal control: text, decimal keyboard, no autofill" do
      assigns = %{}

      tag =
        render(~H"""
        <.decimal_input bare id="q" name="value" value={Decimal.new("2.50")} />
        """)
        |> input_tag()

      assert tag =~ ~s(type="text")
      assert tag =~ ~s(inputmode="decimal")
      assert tag =~ ~s(autocomplete="off")
      assert tag =~ ~s(value="2.5")
    end

    test "the host's classes go on the control, with no full width to fight them" do
      assigns = %{}

      tag =
        render(~H"""
        <.decimal_input bare id="q" name="value" value="1" class="join-item w-20" />
        """)
        |> input_tag()

      assert tag =~ "input "
      assert tag =~ "join-item w-20"
      refute tag =~ "w-full"
      refute tag =~ "input-error"
    end

    test "a bound field supplies name, id, value and errors to the bare control too" do
      changeset =
        {%{}, %{qty: :decimal}}
        |> Ecto.Changeset.cast(%{"qty" => "abc"}, [:qty])
        |> Map.put(:action, :validate)

      assigns = %{form: to_form(changeset, as: "row")}

      html =
        render(~H"""
        <.decimal_input bare field={@form[:qty]} label="Quantity" />
        """)

      assert html =~ ~r/\A<input [^>]*\/?>\z/
      assert html =~ ~s(name="row[qty]")
      assert html =~ ~s(id="row_qty")
      assert html =~ ~s(value="abc")
      assert html =~ "input-error"
      refute html =~ "is invalid"
    end

    test "errors still mark the control" do
      assigns = %{}

      tag =
        render(~H"""
        <.decimal_input bare id="q" name="value" value="x" errors={["is invalid"]} />
        """)
        |> input_tag()

      assert tag =~ "input-error"
    end

    test "the zero handlers and the host's own, chained, and phx attributes all stay" do
      assigns = %{}

      tag =
        render(~H"""
        <.decimal_input
          bare
          id="q"
          name="value"
          value="0"
          onfocus="hostFocus()"
          phx-blur="qty_commit"
          phx-value-uuid="u-1"
          aria-label="Quantity"
        />
        """)
        |> input_tag()

      assert tag =~ ~r/onfocus="[^"]*__pkZero[^"]*;hostFocus\(\)"/
      assert tag =~ ~s( onblur=")
      assert tag =~ ~s( onkeydown=")
      assert tag =~ ~s(phx-blur="qty_commit")
      assert tag =~ ~s(phx-value-uuid="u-1")
      assert tag =~ ~s(aria-label="Quantity")
    end
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

  # An inline handler as the browser reads it: the markup HTML-escapes
  # the attribute value (' → &#39;, > → &gt;).
  defp handler(tag, name) do
    [js] = Regex.run(~r/ #{name}="([^"]*)"/, tag, capture: :all_but_first)

    js
    |> String.replace("&#39;", "'")
    |> String.replace("&gt;", ">")
    |> String.replace("&lt;", "<")
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
  end

  defp zero_tag(extra \\ %{}) do
    assigns = %{extra: extra}

    render(~H"""
    <.decimal_input id="qty" name="qty" value={Decimal.new("0")} {@extra} />
    """)
    |> input_tag()
  end

  test "a zero empties itself on focus and comes back when the field is left empty" do
    tag = zero_tag()
    onfocus = handler(tag, "onfocus")
    onblur = handler(tag, "onblur")

    # focus: only a zero-like text is cleared, and it is remembered
    assert onfocus =~ "this.__pkZero=this.value"
    assert onfocus =~ "this.value=''"
    [regex] = Regex.run(~r{^if\(!this\.readOnly&&/(.*)/\.test}, onfocus, capture: :all_but_first)
    js_zero = ~r/#{regex}/

    for zero <- ["0", "0,00", "0.0", " 0 ", "-0", ",0", "00"], do: assert(zero =~ js_zero)
    for other <- ["", "1", "0,5", "10", "2.5", "0x"], do: refute(other =~ js_zero)

    # blur: the remembered zero returns only when nothing was entered
    assert onblur =~ "this.value.trim()===''"
    assert onblur =~ "this.value=this.__pkZero"
    assert onblur =~ "delete this.__pkZero"
  end

  # LiveView's patch of a focused input removes every attribute the
  # server did not render, so a zero parked in `data-*` would be lost on
  # any re-render while the field is focused and never come back.
  test "the remembered zero never lives in a data- attribute" do
    tag = zero_tag()

    for name <- ~w(onfocus onblur onkeydown), do: refute(handler(tag, name) =~ "dataset")
  end

  # The handlers themselves, run in node on a stand-in element — the
  # attribute strings above only prove the wiring. Skipped without node.
  describe "in a browser-like run" do
    setup do
      case System.find_executable("node") do
        nil -> {:ok, node: nil}
        node -> {:ok, node: node}
      end
    end

    # Steps: "focus", "blur", {"type", text}, {"key", key}. Returns the
    # value after focus, the value at the end, and how many input events
    # the element dispatched on its own.
    defp run(node, value, steps, opts \\ []) do
      tag = zero_tag()
      fun = &Jason.encode!(handler(tag, &1))

      js_steps =
        Enum.map_join(steps, "\n", fn
          "focus" ->
            "focus.call(el, {}); if (focused === undefined) focused = el.value;"

          "blur" ->
            "blur.call(el, {});"

          {"key", key} ->
            "keydown.call(el, {key: #{Jason.encode!(key)}});"

          {"type", text} ->
            "el.value = #{Jason.encode!(text)}; typing = true; el.dispatchEvent(new Event('input')); typing = false;"
        end)

      script = """
      const el = Object.assign(new EventTarget(), {value: #{Jason.encode!(value)}, readOnly: #{!!opts[:readonly]}});
      let own = 0, typing = false, focused;
      el.addEventListener('input', () => { if (!typing) own++ });
      const focus = new Function('event', #{fun.("onfocus")});
      const blur = new Function('event', #{fun.("onblur")});
      const keydown = new Function('event', #{fun.("onkeydown")});
      #{js_steps}
      process.stdout.write(JSON.stringify([focused, el.value, own]));
      """

      {out, 0} = System.cmd(node, ["-e", script])
      Jason.decode!(out)
    end

    test "0 clears on focus and returns on blur, typed text stays", %{node: node} do
      if node do
        assert run(node, "0", ["focus", "blur"]) == ["", "0", 0]
        assert run(node, "0", ["focus", {"type", "8"}, "blur"]) == ["", "8", 0]
        assert run(node, "0,00", ["focus", "blur"]) == ["", "0,00", 0]
        assert run(node, "0,00", ["focus", {"type", "15"}, "blur"]) == ["", "15", 0]
        assert run(node, "2.5", ["focus", "blur"]) == ["2.5", "2.5", 0]
        assert run(node, "2.5", ["focus", {"type", "3"}, "blur"]) == ["2.5", "3", 0]
        assert run(node, "", ["focus", "blur"]) == ["", "", 0]
      end
    end

    test "typed then erased: the zero returns and announces itself once", %{node: node} do
      if node do
        steps = ["focus", {"type", "5"}, {"type", ""}, "blur"]
        assert run(node, "0", steps) == ["", "0", 1]

        # the next untouched focus/blur does not re-announce
        assert run(node, "0", steps ++ ["focus", "blur"]) == ["", "0", 1]
      end
    end

    test "Enter in the emptied field puts the zero back before the submit", %{node: node} do
      if node do
        assert run(node, "0", ["focus", {"key", "Enter"}]) == ["", "0", 0]
        assert run(node, "0", ["focus", {"key", "Enter"}, "blur"]) == ["", "0", 0]
        assert run(node, "0", ["focus", {"key", "a"}]) == ["", "", 0]
        assert run(node, "0", ["focus", {"type", "4"}, {"key", "Enter"}]) == ["", "4", 0]
      end
    end

    test "a readonly zero is left alone", %{node: node} do
      if node do
        assert run(node, "0", ["focus", {"key", "Enter"}, "blur"], readonly: true) ==
                 ["0", "0", 0]
      end
    end
  end

  test "a host's own onfocus/onblur/onkeydown run after the component's, in the same attribute" do
    tag =
      zero_tag(%{onfocus: "HOST_FOCUS()", onblur: "HOST_BLUR()", onkeydown: "HOST_KEY()"})

    for name <- ~w(onfocus onblur onkeydown) do
      assert length(Regex.scan(~r/ #{name}="/, tag)) == 1
    end

    assert handler(tag, "onfocus") =~ ~r/this\.value=''\};HOST_FOCUS\(\)$/
    assert handler(tag, "onblur") =~ ~r/delete this\.__pkZero\};HOST_BLUR\(\)$/
    assert handler(tag, "onkeydown") =~ ~r/delete this\.__pkZero\};HOST_KEY\(\)$/
  end

  test "the unit variant carries the same focus, blur and keydown handlers" do
    assigns = %{}

    tag =
      render(~H"""
      <.decimal_input id="w" name="w" value={Decimal.new("0")} unit="kg" />
      """)
      |> input_tag()

    for name <- ~w(onfocus onblur onkeydown), do: assert(tag =~ ~s( #{name}="))
  end
end
