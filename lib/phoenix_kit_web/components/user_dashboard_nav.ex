defmodule PhoenixKitWeb.Components.UserDashboardNav do
  @moduledoc """
  User dashboard navigation components for the PhoenixKit user dashboard.
  Provides navigation elements specifically for user dashboard pages.
  """

  use PhoenixKitWeb, :html

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Core.LanguageSwitcher

  @doc """
  Renders user dropdown for dashboard navigation.
  Shows user avatar with dropdown menu containing email, role, settings and logout.
  """
  attr(:scope, :any, default: nil)
  attr(:current_path, :string, default: "")
  attr(:current_locale, :string, default: "en")
  attr(:admin_edit_url, :string, default: nil)
  attr(:admin_edit_label, :string, default: nil)

  def user_dropdown(assigns) do
    user = Scope.user(assigns.scope)

    assigns =
      assigns
      |> assign(:user, user)

    ~H"""
    <%= if @scope && PhoenixKit.Users.Auth.Scope.authenticated?(@scope) do %>
      <div class="dropdown dropdown-end">
        <div
          tabindex="0"
          role="button"
          class="cursor-pointer hover:opacity-80 transition-opacity"
        >
          <PhoenixKitWeb.Components.Core.UserInfo.user_avatar
            user={@user}
            size="md"
            class="!rounded-lg"
          />
        </div>

        <ul
          tabindex="0"
          class="dropdown-content menu bg-base-100 rounded-box z-[60] w-64 p-2 shadow-xl border border-base-300 mt-3 max-h-[calc(100vh-5rem)] overflow-y-auto flex-nowrap"
        >
          <li class="menu-title px-4 py-2">
            <div class="flex flex-col gap-1">
              <span class="text-sm font-medium text-base-content truncate">
                {PhoenixKit.Users.Auth.Scope.user_email(@scope)}
              </span>
            </div>
          </li>

          <div class="divider my-0"></div>

          <%= if PhoenixKit.Users.Auth.Scope.admin?(@scope) do %>
            <li>
              <.link
                navigate={PhoenixKit.Utils.Routes.path("/admin")}
                class={"flex items-center gap-3" <> if(active_path?(assigns[:current_path], "/admin"), do: " bg-primary text-primary-content", else: "")}
              >
                <.icon name="hero-shield-check" class="w-4 h-4" />
                <span>{gettext("Admin Panel")}</span>
              </.link>
            </li>
            <%= if @admin_edit_url do %>
              <li>
                <a
                  href={@admin_edit_url}
                  class="flex items-center gap-3"
                >
                  <.icon name="hero-pencil-square" class="w-4 h-4" />
                  <span>{@admin_edit_label || "Edit"}</span>
                </a>
              </li>
            <% end %>
          <% end %>

          <li>
            <.link
              navigate={PhoenixKit.Utils.Routes.path("/dashboard", locale: @current_locale)}
              class={"flex items-center gap-3" <> if(active_path?(assigns[:current_path], "/dashboard"), do: " bg-primary text-primary-content", else: "")}
            >
              <.icon name="hero-home" class="w-4 h-4" />
              <span>Dashboard</span>
            </.link>
          </li>

          <li>
            <.link
              navigate={PhoenixKit.Utils.Routes.path("/dashboard/settings", locale: @current_locale)}
              class={"flex items-center gap-3" <> if(active_path?(assigns[:current_path], "/dashboard/settings"), do: " bg-primary text-primary-content", else: "")}
            >
              <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
              <span>Settings</span>
            </.link>
          </li>

          <% user_languages = get_user_languages() %>
          <%= if length(user_languages) > 1 do %>
            <div class="divider my-0"></div>

            <li class="menu-title px-4 py-1">
              <span class="text-xs">Language</span>
            </li>

            <%!--
              Independently scrollable language list — caps at ~5 visible rows.
              Anchors are styled directly (no nested daisyUI <ul class="menu">) so
              the parent menu doesn't apply submenu indent or li-child padding
              that would otherwise force horizontal scroll and leave a weird
              left indent. See admin_nav.ex for the matching pattern.
            --%>
            <li class="p-0 !bg-transparent hover:!bg-transparent focus:!bg-transparent">
              <div class="!p-0 block w-full max-h-60 overflow-y-auto overflow-x-hidden !bg-transparent hover:!bg-transparent focus:!bg-transparent">
                <%= for language <- user_languages do %>
                  <a
                    href={generate_language_switch_url(@current_path, language.code)}
                    class={[
                      "w-full flex items-center gap-3 rounded-lg px-4 py-2 text-sm",
                      "focus:outline-none focus-visible:outline-none",
                      if(language.code == @current_locale,
                        do:
                          "bg-primary !text-primary-content hover:bg-primary hover:!text-primary-content active:!bg-primary/80",
                        else:
                          "!text-base-content hover:bg-base-200 hover:!text-base-content focus:!text-base-content active:!text-base-content active:!bg-base-300"
                      )
                    ]}
                  >
                    <span class="text-lg">{get_language_flag(language.code)}</span>
                    <span>{language.name}</span>
                    <%= if language.code == @current_locale do %>
                      <PhoenixKitWeb.Components.Core.Icons.icon_check class="w-4 h-4 ml-auto" />
                    <% end %>
                  </a>
                <% end %>
              </div>
            </li>
          <% end %>

          <div class="divider my-0"></div>

          <li>
            <.link
              navigate={Routes.path("/users/log-out")}
              method="delete"
              class="flex items-center gap-3 text-error hover:bg-error hover:text-error-content"
            >
              <.icon name="hero-arrow-right-on-rectangle" class="w-4 h-4" />
              <span>Log Out</span>
            </.link>
          </li>
        </ul>
      </div>
    <% else %>
      <.link
        navigate={Routes.path("/users/log-in")}
        class="btn btn-primary btn-sm"
      >
        Login
      </.link>
    <% end %>
    """
  end

  # Helper function to get user languages from Languages module
  # Returns enabled languages or falls back to English if module is disabled
  defp get_user_languages do
    # Get enabled languages from the Languages module
    languages =
      if Languages.enabled?() do
        Languages.get_enabled_languages()
      else
        # Fallback to English when module is disabled
        [%{code: "en-US", name: "English (United States)", is_enabled: true}]
      end

    # Map to expected format with enriched data from predefined languages.
    # The final `dedupe_names/1` call drops the country qualifier when
    # only one dialect of a given base language is configured — the
    # same rule the frontend switcher applies, called from its
    # canonical home in `Core.LanguageSwitcher` so the logic lives in
    # one place.
    languages
    |> Enum.map(fn lang ->
      case Languages.get_predefined_language(lang.code) do
        %{name: name, flag: flag, native: native} ->
          %{code: lang.code, name: name, flag: flag, native: native}

        nil ->
          %{code: lang.code, name: String.upcase(lang.code), flag: "🌐", native: ""}
      end
    end)
    |> LanguageSwitcher.dedupe_names()
  end

  # Helper function to get language flag emoji
  defp get_language_flag(code) when is_binary(code) do
    case Languages.get_predefined_language(code) do
      %{flag: flag} -> flag
      nil -> "🌐"
    end
  end

  # Check if current path matches the given path
  defp active_path?(current_path, path) when is_binary(current_path) and is_binary(path) do
    # Remove PhoenixKit prefix if present
    normalized_path = remove_phoenix_kit_prefix(current_path)
    # Remove locale prefix if present
    clean_path = remove_locale_prefix(normalized_path)

    # Check for exact match or ends with path
    clean_path == path or String.ends_with?(clean_path, path)
  end

  defp active_path?(_, _), do: false

  # Remove PhoenixKit prefix
  defp remove_phoenix_kit_prefix(path) do
    url_prefix = PhoenixKit.Config.get_url_prefix()

    if url_prefix == "/" do
      path
    else
      String.replace_prefix(path, url_prefix, "")
    end
  end

  # Remove locale prefix
  defp remove_locale_prefix(path) do
    case String.split(path, "/", parts: 3) do
      ["", locale, rest] when locale != "" and rest != "" ->
        if looks_like_locale?(locale), do: "/" <> rest, else: path

      ["", locale] ->
        if looks_like_locale?(locale), do: "/", else: path

      _ ->
        path
    end
  end

  # Check if it looks like a locale code
  defp looks_like_locale?(locale) do
    String.length(locale) <= 8 and String.match?(locale, ~r/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/)
  end

  # Legacy helper - kept for backward compatibility
  defp generate_language_switch_url(current_path, new_locale) do
    base_code = DialectMapper.extract_base(new_locale)

    # Extract the path without locale and regenerate with new locale
    url_prefix = PhoenixKit.Config.get_url_prefix()
    base_prefix = if url_prefix === "/", do: "", else: url_prefix

    # Remove prefix and locale from current_path
    clean_path =
      current_path
      |> String.replace_prefix(base_prefix, "")
      |> remove_locale_from_path()

    # Generate new path with the new locale
    Routes.path(clean_path, locale: base_code)
  end

  # Remove locale from path
  defp remove_locale_from_path(path) do
    case String.split(path, "/", trim: true) do
      [segment | rest] when byte_size(segment) in [2, 5] ->
        # Check if segment looks like a locale
        if String.length(segment) == 2 or
             (String.length(segment) == 5 and String.contains?(segment, "-")) do
          "/" <> Path.join(rest)
        else
          path
        end

      _ ->
        path
    end
  end
end
