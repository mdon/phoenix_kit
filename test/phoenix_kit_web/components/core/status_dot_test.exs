defmodule PhoenixKitWeb.Components.Core.StatusDotTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.StatusDot

  defp render(template), do: rendered_to_string(template)

  test "up={true} is success, up={false} is error" do
    assigns = %{}

    assert render(~H|<.status_dot up={true} />|) =~ "bg-success"
    assert render(~H|<.status_dot up={false} />|) =~ "bg-error"
  end

  test "an unknown state (neither variant nor up) is neutral, not success" do
    # Defaulting an unknown state to green would report health nobody verified.
    assigns = %{}
    html = render(~H|<.status_dot />|)

    assert html =~ "bg-neutral"
    refute html =~ "bg-success"
  end

  test "variant wins over up" do
    assigns = %{}
    html = render(~H|<.status_dot variant={:warning} up={true} />|)

    assert html =~ "bg-warning"
    refute html =~ "bg-success"
  end

  test "every documented variant renders its own colour" do
    assigns = %{}

    for {variant, class} <- [
          {:success, "bg-success"},
          {:error, "bg-error"},
          {:warning, "bg-warning"},
          {:info, "bg-info"},
          {:neutral, "bg-neutral"}
        ] do
      assigns = Map.put(assigns, :variant, variant)
      assert render(~H|<.status_dot variant={@variant} />|) =~ class
    end
  end

  test "renders the label when given, and no empty span when not" do
    assigns = %{}

    assert render(~H|<.status_dot up={true} label="online" />|) =~ "online"
    refute render(~H|<.status_dot up={true} />|) =~ "opacity-70"
  end

  test "pulse adds the ping layer, absent by default" do
    assigns = %{}

    assert render(~H|<.status_dot variant={:info} pulse />|) =~ "animate-ping"
    refute render(~H|<.status_dot variant={:info} />|) =~ "animate-ping"
  end

  test "each size renders a distinct dot class" do
    assigns = %{}

    sizes =
      for size <- [:xs, :sm, :md] do
        assigns = Map.put(assigns, :size, size)
        html = render(~H|<.status_dot up={true} size={@size} />|)
        [_, cls] = Regex.run(~r/(size-[\d.]+)/, html)
        cls
      end

    assert length(Enum.uniq(sizes)) == 3
  end

  test "extra classes land on the wrapper" do
    assigns = %{}

    assert render(~H|<.status_dot up={true} class="ml-2" />|) =~ "ml-2"
  end

  test "the dot alone is not announced as text to a screen reader" do
    # A bare coloured circle carries meaning only visually; without a label
    # there must be nothing for assistive tech to read out as content.
    assigns = %{}
    html = render(~H|<.status_dot up={false} />|)

    assert html |> String.replace(~r/<[^>]*>/, "") |> String.trim() == ""
  end
end
