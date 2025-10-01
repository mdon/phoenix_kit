defmodule PhoenixKitWeb.Components.LayoutWrapper do
  @moduledoc """
  Dynamic layout wrapper component for Phoenix v1.7- and v1.8+ compatibility.

  This component automatically detects the Phoenix version and layout configuration
  to provide seamless integration with parent applications while maintaining
  backward compatibility.

  ## Usage

  Replace direct layout calls with the wrapper:

      <%!-- OLD (Phoenix v1.7-) --%>
      <%!-- Templates relied on router-level layout config --%>

      <%!-- NEW (Phoenix v1.8+) --%>
      <PhoenixKitWeb.Components.LayoutWrapper.app_layout flash={@flash}>
        <%!-- content --%>
      </PhoenixKitWeb.Components.LayoutWrapper.app_layout>

  ## Configuration

  Configure parent layout in config.exs:

      config :phoenix_kit,
        layout: {MyAppWeb.Layouts, :app}

  """
  use Phoenix.Component
  use PhoenixKitWeb, :verified_routes

  import PhoenixKitWeb.Components.Core.Flash, only: [flash_group: 1]
  import PhoenixKitWeb.Components.AdminNav

  alias PhoenixKit.Module.Languages
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.PhoenixVersion
  alias PhoenixKit.Utils.Routes

  @doc """
  Renders content with the appropriate layout based on configuration and Phoenix version.

  Automatically handles:
  - Phoenix v1.8+ function component layouts
  - Phoenix v1.7- legacy layout configuration
  - Fallback to PhoenixKit layouts when no parent configured
  - Parent layout compatibility with PhoenixKit assigns

  ## Attributes

  - `flash` - Flash messages (required)
  - `phoenix_kit_current_scope` - Current authentication scope (optional)
  - `phoenix_kit_current_user` - Current user (optional, for backwards compatibility)

  ## Inner Block

  - `inner_block` - Content to render within the layout
  """
  attr :flash, :map, default: %{}
  attr :phoenix_kit_current_scope, :any, default: nil
  attr :phoenix_kit_current_user, :any, default: nil
  attr :page_title, :string, default: nil
  attr :current_path, :string, default: nil
  attr :inner_content, :string, default: nil
  attr :project_title, :string, default: "PhoenixKit"
  attr :current_locale, :string, default: "en"

  slot :inner_block, required: false

  def app_layout(assigns) do
    # Handle both inner_content (Phoenix 1.7-) and inner_block (Phoenix 1.8+)
    assigns = normalize_content_assigns(assigns)

    # For admin pages, render simplified layout without parent headers
    if admin_page?(assigns) do
      render_admin_only_layout(assigns)
    else
      case get_layout_config() do
        {module, function} when is_atom(module) and is_atom(function) ->
          render_with_parent_layout(assigns, module, function)

        nil ->
          render_with_phoenix_kit_layout(assigns)
      end
    end
  end

  ## Private Implementation

  # Normalize content assigns to handle both inner_content and inner_block
  defp normalize_content_assigns(assigns) do
    # If we have inner_content but no inner_block, create inner_block from inner_content
    if assigns[:inner_content] && (!assigns[:inner_block] || assigns[:inner_block] == []) do
      inner_content = assigns[:inner_content]

      # Create a synthetic inner_block slot
      inner_block = [
        %{
          inner_block: fn _slot_assigns, _index ->
            Phoenix.HTML.raw(inner_content)
          end
        }
      ]

      Map.put(assigns, :inner_block, inner_block)
    else
      # If we have inner_block but no inner_content, leave as is
      assigns
    end
  end

  # Check if current page is an admin page that needs navigation
  defp admin_page?(assigns) do
    case assigns[:current_path] do
      nil -> false
      path when is_binary(path) -> String.contains?(path, "/admin")
      _ -> false
    end
  end

  # Wrap inner_block with admin navigation if needed
  defp wrap_inner_block_with_admin_nav_if_needed(assigns) do
    if admin_page?(assigns) do
      # Create new inner_block slot that wraps original content with admin navigation
      original_inner_block = assigns[:inner_block]

      new_inner_block = [
        %{
          inner_block: fn _slot_assigns, _index ->
            # Create template assigns with needed values
            template_assigns = %{
              original_inner_block: original_inner_block,
              current_path: assigns[:current_path],
              phoenix_kit_current_scope: assigns[:phoenix_kit_current_scope],
              project_title: assigns[:project_title] || "PhoenixKit",
              current_locale: assigns[:current_locale] || "en"
            }

            assigns = template_assigns

            ~H"""
            <%!-- PhoenixKit Admin Layout following EZNews pattern --%>
            <%!-- Mobile Header (shown only on mobile in admin panel) --%>
            <header class="bg-base-100 shadow-sm border-b border-base-300 lg:hidden">
              <div class="flex items-center justify-between h-16 px-4">
                <%!-- Mobile Menu Button --%>
                <label for="admin-mobile-menu" class="btn btn-square btn-primary drawer-button p-0">
                  <PhoenixKitWeb.Components.Core.Icons.icon_menu />
                </label>

                <%!-- Logo --%>
                <div class="flex items-center">
                  <div class="w-8 h-8 bg-primary rounded-lg flex items-center justify-center mr-2">
                    <PhoenixKitWeb.Components.Core.Icons.icon_shield />
                  </div>
                  <span class="font-bold text-base-content">{@project_title} Admin</span>
                </div>

                <%!-- Theme Switcher Mobile --%>
                <.admin_theme_controller mobile={true} />
              </div>
            </header>

            <div class="drawer lg:drawer-open">
              <input id="admin-mobile-menu" type="checkbox" class="drawer-toggle" />

              <%!-- Main content --%>
              <div class="drawer-content flex flex-col">
                <%!-- Page content from parent layout --%>
                {render_slot(@original_inner_block)}
              </div>

              <%!-- Desktop/Mobile Sidebar (without overlay on desktop) --%>
              <div class="drawer-side">
                <label for="admin-mobile-menu" class="drawer-overlay lg:hidden"></label>
                <aside class="min-h-full w-64 bg-base-100 shadow-lg border-r border-base-300 flex flex-col">
                  <%!-- Sidebar header (desktop only) --%>
                  <div class="px-4 py-6 border-b border-base-300 hidden lg:block">
                    <div class="flex items-center gap-3">
                      <div class="w-8 h-8 bg-primary rounded-lg flex items-center justify-center">
                        <PhoenixKitWeb.Components.Core.Icons.icon_shield />
                      </div>
                      <div>
                        <h2 class="font-bold text-base-content">{@project_title} Admin</h2>
                      </div>
                    </div>
                  </div>

                  <%!-- Navigation (fills available space) --%>
                  <nav class="px-4 py-6 space-y-2 flex-1">
                    <.admin_nav_item
                      href={Routes.locale_aware_path(assigns, "/admin/dashboard")}
                      icon="dashboard"
                      label="Dashboard"
                      current_path={@current_path || ""}
                    />

                    <%!-- Users section with direct link and conditional submenu --%>
                    <.admin_nav_item
                      href={Routes.locale_aware_path(assigns, "/admin/users")}
                      icon="users"
                      label="Users"
                      current_path={@current_path || ""}
                      disable_active={true}
                    />

                    <%= if submenu_open?(@current_path, ["/admin/users", "/admin/users/live_sessions", "/admin/users/sessions", "/admin/users/roles", "/admin/users/referral-codes"]) do %>
                      <%!-- Submenu items --%>
                      <div class="mt-1">
                        <.admin_nav_item
                          href={Routes.locale_aware_path(assigns, "/admin/users")}
                          icon="users"
                          label="Manage Users"
                          current_path={@current_path || ""}
                          nested={true}
                        />

                        <.admin_nav_item
                          href={Routes.locale_aware_path(assigns, "/admin/users/live_sessions")}
                          icon="live_sessions"
                          label="Live Sessions"
                          current_path={@current_path || ""}
                          nested={true}
                        />

                        <.admin_nav_item
                          href={Routes.locale_aware_path(assigns, "/admin/users/sessions")}
                          icon="sessions"
                          label="Sessions"
                          current_path={@current_path || ""}
                          nested={true}
                        />

                        <.admin_nav_item
                          href={Routes.locale_aware_path(assigns, "/admin/users/roles")}
                          icon="roles"
                          label="Roles"
                          current_path={@current_path || ""}
                          nested={true}
                        />

                        <%= if PhoenixKit.ReferralCodes.enabled?() do %>
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/users/referral-codes")}
                            icon="referral_codes"
                            label="Referral Codes"
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        <% end %>
                      </div>
                    <% end %>

                    <%= if PhoenixKit.Emails.enabled?() do %>
                      <%!-- Email section with direct link and conditional submenu --%>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/emails/dashboard")}
                        icon="email"
                        label="Emails"
                        current_path={@current_path || ""}
                        disable_active={true}
                      />

                      <%= if submenu_open?(@current_path, ["/admin/emails", "/admin/emails/dashboard", "/admin/emails/templates", "/admin/emails/queue", "/admin/emails/blocklist"]) do %>
                        <%!-- Email submenu items --%>
                        <div class="mt-1">
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/emails/dashboard")}
                            icon="email"
                            label="Dashboard"
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/emails")}
                            icon="email"
                            label="Emails"
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.path("/admin/emails/templates")}
                            icon="email"
                            label="Templates"
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/emails/queue")}
                            icon="email"
                            label="Queue"
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/emails/blocklist")}
                            icon="email"
                            label="Blocklist"
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        </div>
                      <% end %>
                    <% end %>

                    <.admin_nav_item
                      href={Routes.locale_aware_path(assigns, "/admin/modules")}
                      icon="modules"
                      label="Modules"
                      current_path={@current_path || ""}
                    />

                    <%!-- Settings section with direct link and conditional submenu --%>
                    <.admin_nav_item
                      href={Routes.locale_aware_path(assigns, "/admin/settings")}
                      icon="settings"
                      label="Settings"
                      current_path={@current_path || ""}
                      disable_active={true}
                    />

                    <%= if submenu_open?(@current_path, ["/admin/settings", "/admin/settings/referral-codes", "/admin/settings/emails", "/admin/settings/languages"]) do %>
                      <%!-- Settings submenu items --%>
                      <div class="mt-1">
                        <.admin_nav_item
                          href={Routes.locale_aware_path(assigns, "/admin/settings")}
                          icon="settings"
                          label="General Settings"
                          current_path={@current_path || ""}
                          nested={true}
                        />

                        <%= if PhoenixKit.ReferralCodes.enabled?() do %>
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/settings/referral-codes")}
                            icon="referral_codes"
                            label="Referral Module"
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        <% end %>

                        <%= if PhoenixKit.Emails.enabled?() do %>
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/settings/emails")}
                            icon="email"
                            label="Emails"
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        <% end %>

                        <%= if Languages.enabled?() do %>
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/settings/languages")}
                            icon="language"
                            label="Languages"
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        <% end %>
                      </div>
                    <% end %>
                  </nav>

                  <%!-- Bottom Section: Language Switcher, Theme & User Info --%>
                  <div class="p-4 border-t border-base-300 space-y-3">
                    <%!-- Language Switcher (desktop only) --%>
                    <div class="hidden lg:block">
                      <.admin_language_switcher
                        current_path={@current_path || ""}
                        current_locale={@current_locale || "en"}
                      />
                    </div>

                    <%!-- Theme Controller (desktop only) --%>
                    <div class="hidden lg:block">
                      <.admin_theme_controller mobile={false} />
                    </div>

                    <%!-- User Info --%>
                    <.admin_user_info scope={@phoenix_kit_current_scope} />
                  </div>
                </aside>
              </div>
            </div>

            <%!-- Auto-close mobile drawer on navigation --%>
            <script>
              document.addEventListener('DOMContentLoaded', function() {
                const drawerToggle = document.getElementById('admin-mobile-menu');
                // Close mobile drawer on navigation
                const mainNavLinks = document.querySelectorAll('.drawer-side a');

                mainNavLinks.forEach(link => {
                  link.addEventListener('click', () => {
                    if (drawerToggle && window.innerWidth < 1024) {
                      drawerToggle.checked = false;
                    }
                  });
                });
              });

              // Admin theme controller for PhoenixKit with animated slider
              const adminThemeController = {
                init() {
                  const savedTheme = localStorage.getItem('phoenix_kit_theme') || 'system';
                  this.setTheme(savedTheme);
                  this.setupListeners();
                },

                setTheme(theme) {
                  document.documentElement.setAttribute('data-theme', theme);
                  localStorage.setItem('phoenix_kit_theme', theme);

                  // Update slider position via CSS data attribute
                  document.documentElement.setAttribute('data-theme', theme);

                  // Update active state for all theme buttons
                  document.querySelectorAll('[data-theme-target]').forEach(btn => {
                    if (btn.dataset.themeTarget === theme) {
                      btn.classList.add('text-primary');
                    } else {
                      btn.classList.remove('text-primary');
                    }
                  });
                },

                setupListeners() {
                  // Listen to Phoenix LiveView theme events
                  document.addEventListener('phx:set-admin-theme', (e) => {
                    this.setTheme(e.detail.theme);
                  });
                }
              };

              // Initialize admin theme controller
              adminThemeController.init();
            </script>
            """
          end
        }
      ]

      # Return assigns with new inner_block
      assign(assigns, :inner_block, new_inner_block)
    else
      # Not an admin page, return assigns unchanged
      assigns
    end
  end

  # Check if a submenu should be open based on current path
  defp submenu_open?(current_path, paths) when is_binary(current_path) do
    # Remove PhoenixKit prefix first
    normalized_path = String.replace_prefix(current_path, "/phoenix_kit", "")

    # Remove locale prefix (e.g., /es, /fr, etc.) - keep leading slash
    normalized_path =
      case String.split(normalized_path, "/", parts: 3) do
        ["", locale, rest] when locale != "" and rest != "" ->
          # Check if locale looks like a locale code (2-3 chars)
          if String.length(locale) <= 3 do
            "/" <> rest
          else
            normalized_path
          end

        _ ->
          normalized_path
      end

    Enum.any?(paths, fn path -> String.starts_with?(normalized_path, path) end)
  end

  defp submenu_open?(_, _), do: false

  # Render with parent application layout (Phoenix v1.8+ function component approach)
  defp render_with_parent_layout(assigns, module, function) do
    # Prepare assigns for parent layout compatibility
    assigns = prepare_parent_layout_assigns(assigns)

    # Dynamically call the parent layout function based on Phoenix version
    case PhoenixVersion.get_strategy() do
      :modern ->
        render_modern_parent_layout(assigns, module, function)

      :legacy ->
        render_legacy_parent_layout(assigns, module, function)
    end
  end

  # Phoenix v1.8+ approach - function components
  defp render_modern_parent_layout(assigns, module, function) do
    # Wrap inner content with admin navigation if needed
    assigns = wrap_inner_block_with_admin_nav_if_needed(assigns)

    # Use apply/3 to dynamically call the parent layout function
    apply(module, function, [assigns])
  rescue
    UndefinedFunctionError ->
      # Fallback to PhoenixKit layout if parent function doesn't exist
      render_with_phoenix_kit_layout(assigns)
  end

  # Phoenix v1.7- approach - templates (legacy support)
  defp render_legacy_parent_layout(assigns, _module, _function) do
    # For legacy Phoenix, layouts are handled at router level
    # Wrap inner content with admin navigation if needed
    assigns = wrap_inner_block_with_admin_nav_if_needed(assigns)

    # Just render content without wrapper - layout comes from router
    ~H"""
    {render_slot(@inner_block)}
    """
  end

  # Render admin pages with simplified layout (no parent headers)
  defp render_admin_only_layout(assigns) do
    # Wrap inner content with admin navigation
    assigns = wrap_inner_block_with_admin_nav_if_needed(assigns)

    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme="light" class="[scrollbar-gutter:stable]">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <.live_title default={"#{assigns[:project_title] || "PhoenixKit"} Admin"}>
          {assigns[:page_title] || "Admin"}
        </.live_title>
        <link phx-track-static rel="stylesheet" href="/assets/app.css" />
        <script defer phx-track-static type="text/javascript" src="/assets/app.js" />
      </head>
      <body class="bg-base-200 antialiased">
        <%!-- Admin pages without parent headers --%>
        <main class="min-h-screen">
          <.flash_group flash={@flash} />
          {render_slot(@inner_block)}
        </main>
      </body>
    </html>
    """
  end

  # Fallback to PhoenixKit's own layout
  defp render_with_phoenix_kit_layout(assigns) do
    # Wrap inner content with admin navigation if needed
    assigns = wrap_inner_block_with_admin_nav_if_needed(assigns)

    ~H"""
    <PhoenixKitWeb.Layouts.app {prepare_phoenix_kit_assigns(assigns)}>
      {render_slot(@inner_block)}
    </PhoenixKitWeb.Layouts.app>
    """
  end

  # Prepare assigns for parent layout compatibility
  defp prepare_parent_layout_assigns(assigns) do
    assigns
    |> Map.put_new(:current_user, get_current_user_for_parent(assigns))
    |> Map.put_new(:phoenix_kit_integrated, true)
    |> Map.put_new(:phoenix_kit_version, get_phoenix_kit_version())
    |> Map.put_new(:phoenix_version_info, PhoenixVersion.get_version_info())
  end

  # Prepare assigns specifically for PhoenixKit layout
  defp prepare_phoenix_kit_assigns(assigns) do
    assigns
    |> Map.put_new(:phoenix_kit_standalone, true)
  end

  # Extract current user from scope for parent layout compatibility
  defp get_current_user_for_parent(assigns) do
    case assigns[:phoenix_kit_current_scope] do
      nil -> assigns[:phoenix_kit_current_user]
      scope -> Scope.user(scope)
    end
  end

  # Get layout configuration from application environment with Phoenix version compatibility
  defp get_layout_config do
    case Application.get_env(:phoenix_kit, :phoenix_version_strategy) do
      :modern ->
        # Phoenix v1.8+ - get layouts_module and assume :app function
        case Application.get_env(:phoenix_kit, :layouts_module) do
          nil -> nil
          module -> {module, :app}
        end

      :legacy ->
        # Phoenix v1.7- - use legacy layout config
        Application.get_env(:phoenix_kit, :layout)

      nil ->
        # Fallback - check for legacy layout config first
        Application.get_env(:phoenix_kit, :layout)
    end
  end

  # Get PhoenixKit version
  defp get_phoenix_kit_version do
    case Application.spec(:phoenix_kit) do
      nil ->
        "unknown"

      spec ->
        spec
        |> Keyword.get(:vsn, "unknown")
        |> to_string()
    end
  end

  # Language switcher component for admin sidebar
  attr :current_path, :string, required: true
  attr :current_locale, :string, default: "en"

  defp admin_language_switcher(assigns) do
    # Only show if languages are enabled and there are enabled languages
    if Languages.enabled?() do
      enabled_languages = Languages.get_enabled_languages()

      # Only show if there are multiple languages (more than current one)
      if length(enabled_languages) > 1 do
        current_language =
          Enum.find(enabled_languages, &(&1["code"] == assigns.current_locale)) ||
            %{"code" => assigns.current_locale, "name" => String.upcase(assigns.current_locale)}

        other_languages = Enum.reject(enabled_languages, &(&1["code"] == assigns.current_locale))

        assigns =
          assigns
          |> assign(:enabled_languages, enabled_languages)
          |> assign(:current_language, current_language)
          |> assign(:other_languages, other_languages)

        ~H"""
        <div class="dropdown dropdown-end w-full" style="position: relative;">
          <%!-- Current Language Button --%>
          <div tabindex="0" role="button" class="btn btn-outline btn-sm w-full justify-start">
            <span class="text-lg">{get_language_flag(@current_language["code"])}</span>
            <span class="truncate flex-1 text-left">{@current_language["name"]}</span>
            <span class="text-xs">▲</span>
          </div>

          <%!-- Language Options Dropdown --%>
          <ul
            tabindex="0"
            class="dropdown-content menu bg-base-100 rounded-box z-50 w-full p-2 shadow-lg border border-base-300"
            style="position: absolute; bottom: 100%; margin-bottom: 4px;"
          >
            <%= for language <- @other_languages do %>
              <li>
                <a
                  href={generate_language_switch_url(@current_path, language["code"])}
                  class="flex items-center gap-3 px-3 py-2 hover:bg-base-200 rounded-lg"
                >
                  <span class="text-lg">{get_language_flag(language["code"])}</span>
                  <span>{language["name"]}</span>
                </a>
              </li>
            <% end %>
          </ul>
        </div>
        """
      else
        ~H""
      end
    else
      ~H""
    end
  end

  # Helper function to get language flag emoji
  defp get_language_flag(code) do
    case code do
      "en" -> "🇺🇸"
      "es" -> "🇪🇸"
      "fr" -> "🇫🇷"
      "de" -> "🇩🇪"
      "pt" -> "🇵🇹"
      "it" -> "🇮🇹"
      "nl" -> "🇳🇱"
      "ru" -> "🇷🇺"
      "zh-CN" -> "🇨🇳"
      "ja" -> "🇯🇵"
      _ -> "🌐"
    end
  end

  # Helper function to generate language switch URL
  defp generate_language_switch_url(current_path, new_locale) do
    # Get actual enabled language codes to properly detect locale prefixes
    # Note: This function is only called when languages are enabled
    enabled_language_codes = Languages.get_enabled_language_codes()

    # Remove PhoenixKit prefix if present
    normalized_path = String.replace_prefix(current_path || "", "/phoenix_kit", "")

    # Remove existing locale prefix only if it matches actual language codes
    clean_path =
      case String.split(normalized_path, "/", parts: 3) do
        ["", potential_locale, rest] ->
          if potential_locale in enabled_language_codes do
            "/" <> rest
          else
            normalized_path
          end

        _ ->
          normalized_path
      end

    # Generate new URL with the target locale
    Routes.path(clean_path, locale: new_locale)
  end
end
