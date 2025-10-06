defmodule PhoenixKitWeb.Components.AdminNav do
  @moduledoc """
  Admin navigation components for the PhoenixKit admin panel.
  Provides consistent navigation elements for both desktop sidebar and mobile drawer.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.ThemeConfig

  import PhoenixKitWeb.Components.Core.Icon

  @doc """
  Renders an admin navigation item with proper active state styling.

  ## Examples

      <.admin_nav_item
        href={Routes.locale_aware_path(assigns,"/admin/dashboard")}
        icon="dashboard"
        label="Dashboard"
        current_path={Routes.locale_aware_path(assigns,"/admin/dashboard")}
      />

      <.admin_nav_item
        href={Routes.locale_aware_path(assigns,"/admin/users")}
        icon="users"
        label="Users"
        current_path={Routes.locale_aware_path(assigns,"/admin/dashboard")}
        mobile={true}
      />
  """
  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, default: nil
  attr :current_path, :string, required: true
  attr :mobile, :boolean, default: false
  attr :nested, :boolean, default: false
  attr :disable_active, :boolean, default: false

  def admin_nav_item(assigns) do
    active =
      if assigns.disable_active,
        do: false,
        else: nav_item_active?(assigns.current_path, assigns.href, assigns.nested)

    assigns = assign(assigns, :active, active)

    ~H"""
    <.link
      href={@href}
      class={[
        "flex items-center py-2 rounded-lg text-sm font-medium transition-colors",
        "hover:bg-base-200 group",
        if(@active,
          do: "bg-primary text-primary-content",
          else: "text-base-content hover:text-primary"
        ),
        if(@mobile, do: "w-full", else: ""),
        if(@nested, do: "pl-8 pr-3", else: "px-3")
      ]}
    >
      <%= if @nested do %>
        <%!-- Nested item with custom hero icon --%>
        <%= if String.starts_with?(@icon, "hero-") do %>
          <span class={[@icon, "w-4 h-4 mr-2 flex-shrink-0"]}></span>
          <span class="text-sm truncate">{@label}</span>
        <% else %>
          <div class="w-4 h-4 mr-2 flex-shrink-0">
            <.admin_nav_icon icon={@icon} active={@active} />
          </div>
          <span class="text-sm truncate">{@label}</span>
        <% end %>
      <% else %>
        <.admin_nav_icon icon={@icon} active={@active} />
        <span class="ml-3 font-medium truncate">{@label}</span>
      <% end %>
    </.link>
    """
  end

  @doc """
  Renders an icon for admin navigation items.
  """
  attr :icon, :string, required: true
  attr :active, :boolean, default: false

  def admin_nav_icon(assigns) do
    ~H"""
    <div class="flex-shrink-0">
      <%= case @icon do %>
        <% "dashboard" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_dashboard />
        <% "users" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_users />
        <% "roles" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_roles />
        <% "modules" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_modules />
        <% "settings" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_settings />
        <% "sessions" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_sessions />
        <% "live_sessions" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_live_sessions />
        <% "referral_codes" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_referral_codes />
        <% "email" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_email />
        <% "entities" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_modules />
        <% _ -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_default />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders theme controller for admin panel.
  Based on EZNews theme system with DaisyUI integration.
  """
  attr :mobile, :boolean, default: false

  def admin_theme_controller(assigns) do
    assigns =
      assigns
      |> assign(:dropdown_themes, ThemeConfig.dropdown_themes())
      |> assign(:system_targets, ThemeConfig.slider_targets("system") |> Enum.join(","))
      |> assign(:light_targets, ThemeConfig.slider_targets("light") |> Enum.join(","))
      |> assign(:dark_targets, ThemeConfig.slider_targets("dark") |> Enum.join(","))
      |> assign(:system_primary, ThemeConfig.slider_primary_theme("system"))
      |> assign(:light_primary, ThemeConfig.slider_primary_theme("light"))
      |> assign(:dark_primary, ThemeConfig.slider_primary_theme("dark"))
      |> assign(:system_primary, ThemeConfig.slider_primary_theme("system"))
      |> assign(:light_primary, ThemeConfig.slider_primary_theme("light"))
      |> assign(:dark_primary, ThemeConfig.slider_primary_theme("dark"))

    ~H"""
    <div class="flex flex-col gap-3 w-full">
      <div class="relative w-full" data-theme-dropdown>
          <details class="dropdown dropdown-end dropdown-bottom">
          <summary class="btn btn-sm btn-ghost btn-circle">
            <.icon name="hero-swatch" class="w-5 h-5" />
          </summary>
          <ul
            class="dropdown-content menu w-48 rounded-box border border-base-200 bg-base-100 p-1 shadow-xl z-[60] mt-2"
            tabindex="0"
          >
                  <%!-- data-theme-target={theme.value} --%>
            <%= for theme <- @dropdown_themes do %>
              <li>
                <button
                  type="button"
                  phx-click={JS.dispatch("phx:set-admin-theme", detail: %{theme: theme.value})}
                  data-tip={theme.value}
                  data-theme-target={@system_targets}
                  data-theme-role="dropdown-option"
                  role="option"
                  aria-pressed="false"
                  class="group flex items-center gap-2 rounded-lg px-2 py-1.5 text-xs transition hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary"
                >
                  <%= case theme.type do %>
                    <% :system -> %>
                      <div class="flex h-6 w-6 shrink-0 items-center justify-center rounded-md border border-base-200 bg-base-100 shadow-sm">
                        <PhoenixKitWeb.Components.Core.Icons.icon_system class="size-3 opacity-90" />
                      </div>
                    <% :theme -> %>
                      <div
                        data-theme={theme.preview_theme}
                        class="grid h-6 w-6 shrink-0 grid-cols-2 gap-0.5 rounded-md border border-base-200 bg-base-100 p-0.5 shadow-sm"
                      >
                        <div class="rounded-full bg-base-content"></div>
                        <div class="rounded-full bg-primary"></div>
                        <div class="rounded-full bg-secondary"></div>
                        <div class="rounded-full bg-accent"></div>
                      </div>
                  <% end %>
                  <span class="flex-1 text-left font-medium text-base-content truncate">{theme.label}</span>
                  <PhoenixKitWeb.Components.Core.Icons.icon_check
                    class="size-3 text-primary opacity-0 scale-75 transition-all"
                    data-theme-active-indicator
                  />
                </button>
              </li>
            <% end %>
          </ul>
          </details>
      </div>
    </div>
    """
  end

  @doc """
  Renders user dropdown for top bar navigation.
  Shows user avatar with dropdown menu containing email, role, settings and logout.
  """
  attr :scope, :any, default: nil

  def admin_user_dropdown(assigns) do
    ~H"""
    <%= if @scope && PhoenixKit.Users.Auth.Scope.authenticated?(@scope) do %>
      <div class="dropdown dropdown-end">
        <%!-- User Avatar Button --%>
        <div
          tabindex="0"
          role="button"
          class="w-10 h-10 rounded-full bg-primary flex items-center justify-center text-primary-content font-bold cursor-pointer hover:opacity-80 transition-opacity"
        >
          {String.first(PhoenixKit.Users.Auth.Scope.user_email(@scope) || "?") |> String.upcase()}
        </div>

        <%!-- Dropdown Menu --%>
        <ul tabindex="0" class="dropdown-content menu bg-base-100 rounded-box z-[60] w-64 p-2 shadow-xl border border-base-300 mt-3">
          <%!-- User Info Header --%>
          <li class="menu-title px-4 py-2">
            <div class="flex flex-col gap-1">
              <span class="text-sm font-medium text-base-content truncate">
                {PhoenixKit.Users.Auth.Scope.user_email(@scope)}
              </span>
              <div>
                <%= if PhoenixKit.Users.Auth.Scope.owner?(@scope) do %>
                  <div class="badge badge-error badge-xs">Owner</div>
                <% else %>
                  <%= if PhoenixKit.Users.Auth.Scope.admin?(@scope) do %>
                    <div class="badge badge-warning badge-xs">Admin</div>
                  <% else %>
                    <div class="badge badge-ghost badge-xs">User</div>
                  <% end %>
                <% end %>
              </div>
            </div>
          </li>

          <div class="divider my-0"></div>

          <%!-- Settings Link --%>
          <li>
            <.link
              href={Routes.locale_aware_path(assigns, "/users/settings")}
              class="flex items-center gap-3"
            >
              <PhoenixKitWeb.Components.Core.Icons.icon_settings class="w-4 h-4" />
              <span>Settings</span>
            </.link>
          </li>

          <%!-- Log Out Link --%>
          <li>
            <.link
              href={Routes.locale_aware_path(assigns, "/users/log-out")}
              method="delete"
              class="flex items-center gap-3 text-error hover:bg-error hover:text-error-content"
            >
              <PhoenixKitWeb.Components.Core.Icons.icon_logout class="w-4 h-4" />
              <span>Log Out</span>
            </.link>
          </li>
        </ul>
      </div>
    <% else %>
      <%!-- Not Authenticated - Show Login Button --%>
      <.link
        href={Routes.locale_aware_path(assigns, "/users/log-in")}
        class="btn btn-primary btn-sm"
      >
        Login
      </.link>
    <% end %>
    """
  end

  @doc """
  Renders user information section for admin panel sidebar.
  Shows current user email and role information.
  """
  attr :scope, :any, default: nil

  def admin_user_info(assigns) do
    ~H"""
    <%= if @scope && PhoenixKit.Users.Auth.Scope.authenticated?(@scope) do %>
      <div class="bg-base-200 rounded-lg p-3 text-sm">
        <div class="flex items-center gap-2 mb-2">
          <div class="w-8 h-8 bg-primary rounded-full flex items-center justify-center text-primary-content text-xs font-bold">
            {String.first(PhoenixKit.Users.Auth.Scope.user_email(@scope) || "?") |> String.upcase()}
          </div>
          <div class="flex-1 min-w-0">
            <div class="truncate text-xs font-medium text-base-content">
              {PhoenixKit.Users.Auth.Scope.user_email(@scope)}
            </div>
            <%= if PhoenixKit.Users.Auth.Scope.owner?(@scope) do %>
              <div class="badge badge-error badge-xs">Owner</div>
            <% else %>
              <%= if PhoenixKit.Users.Auth.Scope.admin?(@scope) do %>
                <div class="badge badge-warning badge-xs">Admin</div>
              <% else %>
                <div class="badge badge-ghost badge-xs">User</div>
              <% end %>
            <% end %>
          </div>
        </div>

        <div class="flex gap-1">
          <.link
            href={Routes.locale_aware_path(assigns, "/users/settings")}
            class="btn btn-ghost btn-xs flex-1"
          >
            <PhoenixKitWeb.Components.Core.Icons.icon_settings class="w-3 h-3" />
          </.link>

          <.link
            href={Routes.locale_aware_path(assigns, "/users/log-out")}
            method="delete"
            class="btn btn-ghost btn-xs flex-1 text-error hover:bg-error hover:text-error-content"
          >
            <PhoenixKitWeb.Components.Core.Icons.icon_logout />
          </.link>
        </div>
      </div>
    <% else %>
      <div class="bg-base-200 rounded-lg p-3 text-center text-sm">
        <div class="text-base-content/70 mb-2">Not authenticated</div>
        <.link
          href={Routes.locale_aware_path(assigns, "/users/log-in")}
          class="btn btn-primary btn-sm w-full"
        >
          Login
        </.link>
      </div>
    <% end %>
    """
  end

  # Helper function to determine if navigation item is active
  defp nav_item_active?(current_path, href, nested) do
    current_parts = parse_admin_path(current_path)
    href_parts = parse_admin_path(href)

    exact_match?(current_parts, href_parts) or
      tab_match?(current_parts, href_parts) or
      parent_match?(current_parts, href_parts) or
      (!nested and hierarchical_match?(current_parts, href_parts))
  end

  defp hierarchical_match?(current_parts, href_parts) do
    String.starts_with?(current_parts.base_path, href_parts.base_path <> "/")
  end

  # Check if paths match exactly
  defp exact_match?(current_parts, href_parts) do
    href_parts.base_path == current_parts.base_path &&
      is_nil(href_parts.tab) &&
      is_nil(current_parts.tab)
  end

  # Check if tab-specific paths match
  defp tab_match?(current_parts, href_parts) do
    href_parts.base_path == current_parts.base_path &&
      href_parts.tab == current_parts.tab
  end

  # Check if parent page matches when on a tab
  defp parent_match?(current_parts, href_parts) do
    href_parts.base_path == current_parts.base_path &&
      is_nil(href_parts.tab) &&
      not is_nil(current_parts.tab)
  end

  # Helper function to parse admin path into components
  defp parse_admin_path(path) when is_binary(path) do
    # Remove query parameters and split path
    [path_part | _] = String.split(path, "?")

    # Get dynamic prefix and normalize paths
    prefix = PhoenixKit.Config.get_url_prefix()
    admin_prefix = if prefix == "/", do: "/admin", else: "#{prefix}/admin"

    base_path =
      path_part
      |> String.replace_prefix(prefix, "")
      |> strip_locale_segment()
      |> String.replace_prefix(admin_prefix, "")
      |> String.replace_prefix("/admin", "")
      |> case do
        # Default to dashboard for root
        "" -> "dashboard"
        "/" -> "dashboard"
        path -> String.trim_leading(path, "/")
      end

    # Extract tab parameter if present
    tab =
      if String.contains?(path, "?tab=") do
        path
        |> String.split("?tab=")
        |> List.last()
        |> String.split("&")
        |> List.first()
      else
        nil
      end

    %{base_path: base_path, tab: tab}
  end

  defp parse_admin_path(_), do: %{base_path: "dashboard", tab: nil}

  defp strip_locale_segment(path) do
    case String.split(path, "/", parts: 3) do
      ["", locale, rest] when rest != "" ->
        if locale_candidate?(locale) do
          "/" <> rest
        else
          path
        end

      _ ->
        path
    end
  end

  defp locale_candidate?(locale) do
    String.length(locale) in 2..5 and Regex.match?(~r/^[a-z]{2}(?:-[A-Za-z0-9]{2,})?$/, locale)
  end
end
