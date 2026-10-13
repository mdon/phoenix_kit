defmodule PhoenixKitWeb.Components.Core.IntegrationsUIInstructionsTest do
  @moduledoc """
  `setup_instructions/1` picks its sections by `scope`. A caller that names no
  scope is a personal page (the surface that predates the site/personal split),
  so it must not show the sections written for the admin.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.Core.IntegrationsUI

  @provider %{
    instructions: [
      %{title: "For the admin", scopes: [:system], steps: [{"admin step", nil}]},
      %{title: "For the user", scopes: [:personal], steps: [{"user step", nil}]},
      %{title: "For everyone", steps: [{"shared step", nil}]}
    ]
  }

  test "no scope means the personal sections" do
    html = render_component(&IntegrationsUI.setup_instructions/1, provider: @provider)

    assert html =~ "For the user"
    assert html =~ "For everyone"
    refute html =~ "For the admin"
  end

  test "the system scope shows the admin sections instead" do
    html =
      render_component(&IntegrationsUI.setup_instructions/1,
        provider: @provider,
        scope: :system
      )

    assert html =~ "For the admin"
    assert html =~ "For everyone"
    refute html =~ "For the user"
  end
end
