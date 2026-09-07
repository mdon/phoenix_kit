defmodule PhoenixKitWeb.Components.Core.WebsiteAccessBadges do
  @moduledoc """
  The header's reminder of what is standing between the world and this
  site: a lock while the password gate is on, a wrench while maintenance
  is active, an arrow while the redirect to production is on. Each links
  to the Website access settings page. Nothing renders when everything is
  off, so a live site's header stays as it was.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.WebsiteAccess.{Gate, Redirect}

  attr :current_locale, :any, default: nil
  attr :class, :any, default: nil

  def website_access_badges(assigns) do
    assigns =
      assigns
      |> assign(:badges, badges())
      |> assign(
        :path,
        Routes.path("/admin/settings/website-access", locale: assigns.current_locale)
      )

    ~H"""
    <.link
      :for={{icon, title, class} <- @badges}
      navigate={@path}
      class={["tooltip tooltip-bottom flex items-center", class, @class]}
      data-tip={title}
      aria-label={title}
    >
      <.icon name={icon} class="w-5 h-5" />
    </.link>
    """
  end

  defp badges do
    [
      Gate.enabled?() && {"hero-lock-closed", gettext("Password gate is on"), "text-warning"},
      Maintenance.active?() &&
        {"hero-wrench-screwdriver", gettext("Maintenance is on"), "text-warning"},
      Redirect.enabled?() &&
        {"hero-arrow-top-right-on-square", gettext("Redirecting visitors to production"),
         "text-info"}
    ]
    |> Enum.filter(& &1)
  rescue
    _ -> []
  end
end
