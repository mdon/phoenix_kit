defmodule PhoenixKitWeb.Components.Core.ConnectAccountButtonTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.ConnectAccountButton

  defp render(template), do: rendered_to_string(template)

  test "renders a real anchor carrying the href" do
    # Progressive enhancement rests on this: with JS off or the popup blocked,
    # the plain navigation still starts the OAuth flow.
    assigns = %{}

    html =
      render(~H|<.connect_account_button href="/oauth/start">Connect</.connect_account_button>|)

    assert html =~ ~s(href="/oauth/start")
    assert html =~ "<a"
    assert html =~ "Connect"
  end

  test "drives the popup from a hook, never an inline handler" do
    # An inline onclick is CSP-hostile, and the kit removed inline handlers
    # everywhere else for that reason.
    assigns = %{}

    html = render(~H|<.connect_account_button href="/oauth/start">Go</.connect_account_button>|)

    assert html =~ ~s(phx-hook="PopupLink")
    refute html =~ "onclick"
    refute html =~ "window.open"
  end

  test "popup geometry travels as data attributes, not interpolated script" do
    assigns = %{}

    html =
      render(~H"""
      <.connect_account_button
        href="/oauth/start"
        window_name="shelly"
        window_width={500}
        window_height={700}
      >
        Go
      </.connect_account_button>
      """)

    assert html =~ ~s(data-window-name="shelly")
    assert html =~ ~s(data-window-width="500")
    assert html =~ ~s(data-window-height="700")
  end

  test "a phx-hook element always has an id" do
    # LiveView refuses to attach a hook to an element without one.
    assigns = %{}

    html = render(~H|<.connect_account_button href="/oauth/start">Go</.connect_account_button>|)

    # `~r/id="[^"]+"/` was satisfied by any *-id attribute; pin the real one.
    assert html =~ ~r/\sid="pk-connect-[a-zA-Z0-9_-]+"/
  end

  test "an explicit id wins over the derived default" do
    assigns = %{}

    html =
      render(
        ~H|<.connect_account_button href="/oauth/start" id="my-btn">Go</.connect_account_button>|
      )

    assert html =~ ~s(id="my-btn")
  end

  test "a window name with a quote cannot break out of an attribute" do
    # The old version interpolated this straight into a JS string literal.
    assigns = %{hostile: "x'); alert(1);//"}

    html =
      render(~H"""
      <.connect_account_button href="/oauth/start" window_name={@hostile}>Go</.connect_account_button>
      """)

    # The payload may appear as inert, escaped attribute TEXT — what matters is
    # that it never reaches an executable context and never lands unescaped.
    refute html =~ "onclick"
    refute html =~ "<script"
    refute html =~ ~s(window_name="x';)
    assert html =~ "&#39;", "the quote must be escaped, not emitted raw"

    # The derived DOM id has to stay usable by querySelector.
    [_, id] = Regex.run(~r/id="([^"]*)"/, html)
    assert id =~ ~r/^[a-zA-Z0-9_-]+$/, "unusable derived id: #{inspect(id)}"
  end

  test "refuses a cross-origin href" do
    # The popup keeps window.opener so the callback can refresh the opener;
    # pointing it off-origin would hand that reference to a third party.
    assigns = %{}

    assert_raise ArgumentError, ~r/local path/, fn ->
      render(
        ~H|<.connect_account_button href="https://evil.example/start">Go</.connect_account_button>|
      )
    end
  end

  test "refuses a protocol-relative href" do
    assigns = %{}

    assert_raise ArgumentError, ~r/local path/, fn ->
      render(
        ~H|<.connect_account_button href="//evil.example/start">Go</.connect_account_button>|
      )
    end
  end

  test "custom classes replace the default button styling" do
    assigns = %{}

    html =
      render(
        ~H|<.connect_account_button href="/oauth/start" class="btn btn-outline">Go</.connect_account_button>|
      )

    assert html =~ "btn-outline"
  end

  test "global attributes pass through" do
    assigns = %{}

    html =
      render(
        ~H|<.connect_account_button href="/oauth/start" aria-label="Connect Shelly">Go</.connect_account_button>|
      )

    assert html =~ ~s(aria-label="Connect Shelly")
  end
end
