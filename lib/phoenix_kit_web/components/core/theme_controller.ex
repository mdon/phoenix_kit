defmodule PhoenixKitWeb.Components.Core.ThemeController do
  @moduledoc """
  Shared theme controller component for admin and dashboard.

  Provides a dropdown to select from available daisyUI themes.
  Supports filtering to show only specific themes.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias PhoenixKit.ThemeConfig

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Icons, only: [icon_system: 1, icon_check: 1]

  @doc """
  Renders a theme controller dropdown.

  ## Attributes

  - `themes` - List of theme names to show, or `:all` for all themes (default: `:all`)
  - `id` - Unique ID for the dropdown (default: "theme-dropdown")
  - `class` - Additional CSS classes

  ## Examples

      <%!-- All themes --%>
      <.theme_controller />

      <%!-- Only specific themes --%>
      <.theme_controller themes={["system", "light", "dark", "nord", "dracula"]} />

      <%!-- From config --%>
      <.theme_controller themes={Application.get_env(:phoenix_kit, :dashboard_themes, :all)} />
  """
  attr :themes, :any, default: :all
  attr :id, :string, default: "theme-dropdown"
  attr :class, :string, default: nil
  attr :rest, :global

  def theme_controller(assigns) do
    dropdown_themes = ThemeConfig.dropdown_themes(assigns.themes)

    assigns = assign(assigns, :dropdown_themes, dropdown_themes)

    # Exactly two concrete themes is a light/dark pair, and a dropdown for a
    # binary choice is ceremony — render a toggle instead. The behaviour is
    # keyed on the LIST, not a new option, so a host that narrows
    # :dashboard_themes to its two branded themes gets the toggle without
    # learning anything new. "system" keeps the dropdown: three states need a
    # menu.
    if match?([%{type: :theme}, %{type: :theme}], dropdown_themes) do
      theme_toggle_pair(assigns)
    else
      theme_dropdown(assigns)
    end
  end

  # One button per theme, each dispatching the same phx:set-theme event the
  # dropdown uses; the layout JS hides whichever button's theme is ACTIVE, so
  # what remains visible is the one you'd switch to — sun offers light, moon
  # offers dark, exactly one at a time. Before that JS first runs both are
  # rendered; it resolves on the same tick as the initial theme application.
  defp theme_toggle_pair(assigns) do
    ~H"""
    <div class={["flex items-center", @class]} {@rest} data-theme-toggle id={@id}>
      <button
        :for={theme <- @dropdown_themes}
        type="button"
        phx-click={JS.dispatch("phx:set-theme", detail: %{theme: theme.value})}
        data-theme-target={theme.value}
        data-theme-role="toggle-option"
        title={theme.label}
        aria-label={theme.label}
        class="btn btn-sm btn-ghost btn-circle"
      >
        <.icon
          name={if toggle_base(theme.value) == "dark", do: "hero-moon", else: "hero-sun"}
          class="w-5 h-5"
        />
      </button>
    </div>
    """
  end

  defp toggle_base(theme), do: Map.get(ThemeConfig.base_map(), theme, "light")

  defp theme_dropdown(assigns) do
    ~H"""
    <div class={["flex flex-col gap-3 w-full", @class]} {@rest}>
      <div class="relative w-full" data-theme-dropdown>
        <details class="dropdown dropdown-end dropdown-bottom" id={@id}>
          <summary class="btn btn-sm btn-ghost btn-circle">
            <.icon name="hero-swatch" class="w-5 h-5" />
          </summary>
          <ul
            class="dropdown-content w-72 min-w-0 rounded-box border border-base-200 bg-base-100 p-2 shadow-xl z-[60] mt-2 max-h-[80vh] overflow-y-auto overflow-x-hidden list-none space-y-1"
            tabindex="0"
            phx-click-away={JS.remove_attribute("open", to: "##{@id}")}
          >
            <%= for theme <- @dropdown_themes do %>
              <li class="w-full">
                <button
                  type="button"
                  phx-click={JS.dispatch("phx:set-theme", detail: %{theme: theme.value})}
                  data-tip={theme.value}
                  data-theme-target={theme.value}
                  data-theme-role="dropdown-option"
                  role="option"
                  aria-pressed="false"
                  class="w-full group flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary cursor-pointer"
                >
                  <%= case theme.type do %>
                    <% :system -> %>
                      <div class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-base-200 bg-base-100 shadow-sm">
                        <.icon_system class="size-4 opacity-90" />
                      </div>
                    <% :theme -> %>
                      <div
                        data-theme={theme.preview_theme}
                        class="grid h-8 w-8 shrink-0 grid-cols-2 gap-0.5 rounded-md border border-base-200 bg-base-100 p-0.5 shadow-sm"
                      >
                        <div class="rounded-full bg-base-content"></div>
                        <div class="rounded-full bg-primary"></div>
                        <div class="rounded-full bg-secondary"></div>
                        <div class="rounded-full bg-accent"></div>
                      </div>
                  <% end %>
                  <span class="flex-1 text-left font-medium text-base-content truncate">
                    {theme.label}
                  </span>
                  <span data-theme-active-indicator>
                    <.icon_check class="size-4 text-primary opacity-0 scale-75 transition-all" />
                  </span>
                </button>
              </li>
            <% end %>
          </ul>
        </details>
      </div>
    </div>
    """
  end
end
