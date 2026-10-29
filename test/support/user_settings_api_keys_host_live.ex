defmodule PhoenixKitWeb.Test.UserSettingsApiKeysHostLive do
  @moduledoc """
  Stand-in for a host page that embeds `UserSettings` with the `:api_keys` section, backing
  test/phoenix_kit_web/live/components/user_settings_api_keys_test.exs.

  The session decides what the host passes: `"user_uuid"` (required), `"scope"` (`false`
  leaves the `scope` assign out) and `"impersonated"` (absent leaves that assign out).
  Not routed; rendered with `Phoenix.LiveViewTest.live_isolated/3`.
  """
  use Phoenix.LiveView

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  @impl true
  def mount(_params, session, socket) do
    user = Auth.get_user(session["user_uuid"])

    extra =
      %{}
      |> put_unless(session["scope"] == false, :scope, Scope.for_user(user))
      |> put_unless(
        not Map.has_key?(session, "impersonated"),
        :impersonated,
        session["impersonated"]
      )

    {:ok, socket |> assign(:user, user) |> assign(:extra, extra), layout: false}
  end

  defp put_unless(map, true, _key, _value), do: map
  defp put_unless(map, false, key, value), do: Map.put(map, key, value)

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={PhoenixKitWeb.Live.Components.UserSettings}
      id="user-settings"
      user={@user}
      sections={[:api_keys]}
      {@extra}
    />
    """
  end
end
