defmodule PhoenixKit.Utils.Routes do
  @moduledoc """
  Utility functions for working with PhoenixKit routes and URLs.

  This module provides helpers for constructing URLs with the correct
  PhoenixKit prefix configured in the application.
  """

  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Users.Auth.Scope

  @default_locale Config.default_locale()

  # List of path prefixes that should NEVER have a locale added.
  # This should be kept in sync with @reserved_segments in LocaleExtractor plug.
  @reserved_prefixes ~w(/api /webhooks /assets /static /files /images /fonts /js /css /sitemap)

  @doc """
  Returns the configured PhoenixKit URL prefix.

  ## Examples

      iex> PhoenixKit.Utils.Routes.url_prefix()
      "/phoenix_kit"

  """
  @spec url_prefix() :: String.t()
  def url_prefix, do: Config.get_url_prefix()

  @doc """
  Returns `true` when `path` is safe to use as a local redirect / `return_to`
  target: a binary that begins with a single `/` but not `//` or `/\\` — both of
  which browsers resolve as protocol-relative, host-switching URLs. Use this to
  guard user-supplied redirect params against open-redirect attacks.

  ASCII control characters are rejected too. Browsers strip tab/CR/LF while
  parsing a URL, so `"/\\t/evil.example"` (from `?return_to=%2F%09%2Fevil.example`)
  becomes `//evil.example` — a cross-origin navigation — once it reaches
  `window.location`. `Phoenix.Controller.redirect/2` blocks those itself, but
  LiveView's `validate_local_url!` only rejects `\\\\` and a leading `//`, so a
  LiveView `redirect(socket, to: ...)` would otherwise pass it through.

  ## Examples

      iex> PhoenixKit.Utils.Routes.local_path?("/admin/dashboard")
      true
      iex> PhoenixKit.Utils.Routes.local_path?("//evil.com")
      false
      iex> PhoenixKit.Utils.Routes.local_path?("https://evil.com")
      false
      iex> PhoenixKit.Utils.Routes.local_path?("/\\t/evil.com")
      false

  """
  @spec local_path?(term()) :: boolean()
  def local_path?(path) when is_binary(path) do
    String.starts_with?(path, "/") and
      not String.starts_with?(path, "//") and
      not String.starts_with?(path, "/\\") and
      not contains_control_char?(path)
  end

  def local_path?(_), do: false

  # ASCII control chars (C0 + DEL). Checked bytewise: a control char is
  # single-byte in UTF-8 and can never appear inside a multi-byte sequence.
  defp contains_control_char?(path) do
    path
    |> :binary.bin_to_list()
    |> Enum.any?(fn byte -> byte <= 0x1F or byte == 0x7F end)
  end

  @doc """
  Resolves where to send a user once they are signed in and confirmed.

  Takes candidate destinations in priority order (e.g. a `?return_to=` param,
  then the session's `user_return_to`) and returns the first that passes
  `local_path?/1`. Falls back to the `after_login_path` setting, and finally
  to `"/"`.

  The setting is validated as a local path when saved, but is re-guarded here
  so a hand-edited DB row can't turn a post-auth redirect into an open
  redirect. Single source of truth for the post-auth landing page — used by
  the login flow (`signed_in_path/1`) and by both confirmation LiveViews.

  ## Examples

      iex> PhoenixKit.Utils.Routes.post_auth_path(["/checkout"])
      "/checkout"
      iex> PhoenixKit.Utils.Routes.post_auth_path(["https://evil.com", nil])
      "/"
      iex> PhoenixKit.Utils.Routes.post_auth_path(["/users/log-out"])
      "/"

  """
  @spec post_auth_path([term()]) :: String.t()
  def post_auth_path(candidates \\ []) when is_list(candidates) do
    Enum.find(candidates, &usable_candidate?/1) || after_login_path()
  end

  # A candidate carries the same two requirements as the setting: local, and
  # not a page that bounces an authenticated visitor. The candidates are the
  # LESS trusted of the two — `?return_to=` is whatever a link contained — so
  # `?return_to=/users/log-out` on any auth link would otherwise sign the user
  # back out the instant they signed in.
  defp usable_candidate?(path), do: local_path?(path) and not auth_page?(path)

  @typedoc """
  The request a redirect is being built for. The application's router is read
  from it, which is how `routable?/2` works. `nil` is accepted — it simply
  makes every candidate fail closed, so the chain lands on a core-owned page.
  """
  @type request_context :: Plug.Conn.t() | Phoenix.LiveView.Socket.t() | nil

  @doc """
  Resolves where to send a visitor that core is *allowed* to send them.

  Replaces every hardcoded `"/"` / `Routes.path("/")` destination in core.
  `Routes.path("/")` emits a locale-prefixed root (`/en`); the route that would
  serve it belongs to the host application, which core cannot declare, so on a
  host that never declared one every such redirect 404s.

  ## The chain

  Authenticated (`opts[:scope]` passes `Scope.authenticated?/1`):

    1. `:return_to` — the untrusted explicit destination
    2. `/admin`, when `Scope.can_access_admin_area?/1` and `:skip_admin` is not set
    3. `/dashboard`
    4. the `after_login_path` setting

  Anonymous:

    1. the `main_page_path` setting, when set and still resolvable
    2. — (falls through to the terminal)

  Every candidate must be a local path (`local_path?/1`), not an auth page
  (`auth_page?/1`), **and actually routable** (`routable?/2`). When nothing
  survives, the terminal is `/admin` for a visitor who may reach the admin area
  and `/users/log-in` for everyone else. Both are declared unconditionally by
  `phoenix_kit_routes()` in every locale, so the fall-through cannot 404.

  ## Options

    * `:scope` — `%PhoenixKit.Users.Auth.Scope{}` or `nil`. **Pass it
      explicitly.** Several call sites run on pipelines that never assign a
      scope, and full logout still carries the just-logged-out user in
      `conn.assigns` after the session has been cleared, so inferring it here
      would answer "authenticated" about someone who no longer is.
    * `:return_to` — a candidate path, or a list of them in priority order.
      Honoured on the authenticated chain only: an anonymous pending
      destination belongs in the `user_return_to` session key, not in a
      redirect.
    * `:skip_admin` — suppress step 2. Required wherever the caller is
      *rejecting* the visitor from the admin area, or the redirect would send
      them straight back to it.

  ## The invariant

  Every value returned is either a path the caller supplied or an administrator
  configured **that has been proven to resolve in the router**, or one of two
  paths core declares itself. There is no third branch, and neither `"/"` nor
  `path("/")` is ever synthesized here. (An administrator who explicitly
  configures `/` on a host that really serves it still gets `/` — that is the
  point: `/` stays a legitimate *candidate*, it just stops being core's
  *choice*.)
  """
  @spec safe_destination(request_context(), keyword()) :: String.t()
  def safe_destination(context, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    admin? = not Keyword.get(opts, :skip_admin, false) and Scope.can_access_admin_area?(scope)

    candidates =
      if Scope.authenticated?(scope) do
        authenticated_candidates(opts, admin?)
      else
        anonymous_candidates()
      end

    found =
      candidates
      # Lazily: candidates are thunks so the settings read at the tail of the
      # chain never happens for a visitor the earlier steps already placed.
      |> Stream.map(& &1.())
      |> Enum.find(&routable_candidate?(context, &1))

    found || terminal(admin?)
  end

  defp authenticated_candidates(opts, admin?) do
    explicit = Enum.map(List.wrap(Keyword.get(opts, :return_to)), fn c -> fn -> c end end)

    explicit ++
      [
        fn -> if admin?, do: path("/admin") end,
        # `/dashboard` is conditionally compiled by the host router
        # (`user_dashboard_enabled`), which is exactly why it is probed with
        # `routable?/2` like any other candidate rather than assumed.
        fn -> path("/dashboard") end,
        fn -> setting_candidate("after_login_path") end
      ]
  end

  defp anonymous_candidates do
    [fn -> main_page_path() end]
  end

  # The terminal is chosen by core, never by input, so it is emitted without a
  # routability probe: both arms are declared unconditionally, in every locale.
  defp terminal(true), do: path("/admin")
  defp terminal(false), do: path("/users/log-in")

  defp routable_candidate?(context, candidate) do
    usable_candidate?(candidate) and routable?(context, candidate)
  end

  # Raw setting read. Deliberately NOT `after_login_path/0`, which substitutes
  # `"/"` when the setting is blank or unsafe — that would smuggle the unowned
  # root back into the chain as a value core synthesized rather than one an
  # administrator chose.
  defp setting_candidate(key) do
    case key |> PhoenixKit.Settings.get_setting_cached("") |> to_string() |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  @doc """
  The configured site main page, or `nil` when unset or unusable.

  `nil` rather than `"/"` is deliberate: `safe_destination/2` drops nil
  candidates and falls through to a core-owned page, where `"/"` would
  reintroduce the unowned path this mechanism exists to remove.

  The setting is validated as a local path when saved and re-guarded here on
  read, so a hand-edited DB row can't turn it into an open redirect.
  """
  @spec main_page_path() :: String.t() | nil
  def main_page_path do
    case setting_candidate("main_page_path") do
      nil -> nil
      value -> if usable_candidate?(value), do: value, else: nil
    end
  end

  @doc """
  Whether `path` actually resolves to a `GET` route in the application's router.

  The router is taken from the request: `conn.private[:phoenix_router]`, set by
  the generated router before dispatch, or `socket.router`, set when the
  LiveView is mounted at the router.

  **When the router cannot be determined this returns `false`.** The two failure
  modes are asymmetric: emitting an unverified path is the 404 this whole
  mechanism exists to eliminate, while skipping the candidate merely falls
  through to a core-owned page that is guaranteed to exist.
  """
  @spec routable?(request_context(), term()) :: boolean()
  def routable?(context, path) when is_binary(path) do
    case router_for(context) do
      nil ->
        false

      router ->
        Phoenix.Router.route_info(router, "GET", path_only(path), host_for(context)) != :error
    end
  rescue
    # A router module that isn't loaded under a release, or a malformed path.
    _ -> false
  catch
    :exit, _ -> false
  end

  def routable?(_context, _path), do: false

  defp router_for(%Plug.Conn{private: private}), do: Map.get(private, :phoenix_router)
  defp router_for(%Phoenix.LiveView.Socket{router: router}), do: router
  defp router_for(_), do: nil

  defp host_for(%Plug.Conn{host: host}) when is_binary(host), do: host

  defp host_for(%Phoenix.LiveView.Socket{host_uri: %URI{host: host}}) when is_binary(host),
    do: host

  # `socket.host_uri` is the atom `:not_mounted_at_router` outside a router, and
  # routes without a `host:` constraint match any host anyway.
  defp host_for(_), do: "localhost"

  # `route_info/4` matches path SEGMENTS, so "/foo?x=1" would be probed as the
  # single segment "foo?x=1" and never match. Same normalisation `auth_page?/1`
  # applies.
  defp path_only(path), do: path |> String.split(["?", "#"], parts: 2) |> hd()

  @doc """
  Renders `?return_to=<path>` for a link, or `""` when there is nothing safe to
  carry. Lets the auth pages hand the pending destination to each other instead
  of dropping it the moment a visitor switches to another sign-in method.
  """
  @spec return_to_query(term()) :: String.t()
  def return_to_query(path) do
    if local_path?(path), do: "?" <> URI.encode_query(%{"return_to" => path}), else: ""
  end

  # Every path that bounces an authenticated visitor elsewhere, plus log-out.
  # Setting the post-login destination to any of them loops forever; pointing
  # it at `/users/log-out` is worse — it is a real GET route, so every
  # successful login immediately signs the user back out and nobody, including
  # the admin who set it, can stay in to undo it.
  # `/users/referral` belongs here for the same reason `/users/confirm` does:
  # the invite-only gate parks users there and stashes where they came from, so
  # without it a stashed `return_to` could send an admitted user straight back
  # to the page that had just released them.
  @auth_paths ~w(/users/log-in /users/log-out /users/register /users/confirm
  /users/referral /users/magic-link /users/qr-login /users/reset-password)

  defp after_login_path do
    path =
      "after_login_path" |> PhoenixKit.Settings.get_setting("/") |> to_string() |> String.trim()

    if local_path?(path) and not auth_page?(path), do: path, else: "/"
  end

  @doc """
  Whether a path lands on one of the sign-in pages (or `/users/log-out`).

  Public because the `after_login_path` / `after_registration_path` changeset
  applies the same rule when the setting is saved — one list, one predicate, so
  a new auth route can't be guarded on read and forgotten on write.

  Suffix-matched, since the real URL carries the host's mount prefix and an
  optional locale segment (`/app/et/users/log-in`). A host page whose own path
  happens to end in one of these segments is refused too — over-strict rather
  than allowing a redirect loop.

  ## Examples

      iex> PhoenixKit.Utils.Routes.auth_page?("/users/log-in")
      true
      iex> PhoenixKit.Utils.Routes.auth_page?("/et/users/log-out/")
      true
      iex> PhoenixKit.Utils.Routes.auth_page?("/dashboard")
      false

  """
  @spec auth_page?(term()) :: boolean()
  def auth_page?(path) when is_binary(path) do
    trimmed = path |> String.split(["?", "#"], parts: 2) |> hd() |> String.trim_trailing("/")
    Enum.any?(@auth_paths, &(trimmed == &1 or String.ends_with?(trimmed, &1)))
  end

  def auth_page?(_), do: false

  @doc """
  Builds a PhoenixKit path: the host's mount prefix, plus a locale segment when
  the site is multilingual.

  ## The `:locale` option

  This is the contract, and it is what a bilingual site needs when auth pages
  come out in the wrong language. Without it the locale is *determined* — from
  the process's Gettext locale — which is right for a link rendered inside a
  request and wrong for a link built outside one (an email, a background job, a
  script).

  - `locale: "et"` — force this locale.
  - `locale: :none` — emit no locale segment at all. For anything that is not a
    page: assets, webhooks, `sitemap.xml`.
  - `locale: nil` or omitted — determine it from the current process.

  ### Examples

      Routes.path("/users/log-in")                 # current locale
      Routes.path("/users/log-in", locale: "et")   # /et/users/log-in
      Routes.path("/sitemap.xml", locale: :none)   # never localized

  Note that the primary language is emitted prefixlessly when the site is
  configured that way, so `locale: "en"` on an English-primary site yields a
  path with no `/en` segment — that is deliberate, not a dropped option.

  See the multilang guide for how locales are resolved and switched; the symptom
  of getting this wrong (English auth pages on a translated site) reads like an
  i18n bug rather than a routing one.
  """
  # NOTE: Locale override logic below exists for the publishing component system integration.
  # Switch to the upcoming media/storage helpers once they land.
  def path(url_path, opts \\ [])

  def path("/" <> _ = url_path, opts) do
    url_prefix = PhoenixKit.Config.get_url_prefix()
    base_path = if url_prefix === "/", do: "", else: url_prefix

    cond do
      # Admin paths follow the same primary-prefixless rule as non-admin
      # paths (see `build_admin_path/3`). The dual-scope router emission
      # keeps `/phoenix_kit/admin/*` AND `/phoenix_kit/:locale/admin/*`
      # both reachable, so the emitted shape is purely cosmetic.
      admin_path?(url_path) ->
        locale = resolve_locale(opts)
        build_admin_path(base_path, url_path, locale)

      # Reserved paths (API, webhooks, assets) NEVER get a locale prefix.
      reserved_path?(url_path) ->
        "#{base_path}#{url_path}"

      true ->
        build_localized_path(base_path, url_path, opts)
    end
  end

  def path(_url_path, _opts) do
    raise """
    Url path must start with "/".
    """
  end

  defp build_localized_path(base_path, url_path, opts) do
    locale = resolve_locale(opts)
    build_path_with_locale(base_path, url_path, locale)
  end

  defp resolve_locale(opts) do
    case Keyword.fetch(opts, :locale) do
      {:ok, :none} -> :none
      {:ok, nil} -> determine_locale()
      {:ok, locale_value} -> locale_value
      :error -> determine_locale()
    end
  end

  defp build_path_with_locale(base_path, url_path, :none), do: "#{base_path}#{url_path}"

  defp build_path_with_locale(base_path, url_path, locale_value) do
    if default_locale?(locale_value) and prefixless_primary?() do
      "#{base_path}#{url_path}"
    else
      locale_prefixed_path(base_path, locale_value, url_path)
    end
  end

  # Builds a locale-prefixed URL (`/{locale}{url_path}`).
  #
  # The bare root (`url_path == "/"`) is special-cased to emit
  # `/{locale}` rather than `/{locale}/`: Phoenix routers do not match a
  # trailing slash, so a `/:locale` landing route declared by the parent
  # app would 404 on `/{locale}/`. Every other path keeps its leading
  # slash, so the concatenation is already correct.
  defp locale_prefixed_path(base_path, locale, "/"), do: "#{base_path}/#{locale}"
  defp locale_prefixed_path(base_path, locale, url_path), do: "#{base_path}/#{locale}#{url_path}"

  # Check if a path is an admin path.
  defp admin_path?(url_path), do: String.starts_with?(url_path, "/admin")

  # Admin paths follow the same primary-prefix rule as non-admin paths.
  # Both URL shapes (`/admin/*` and `/:locale/admin/*`) are emitted by the
  # admin route macros so either shape is routable; the choice between
  # them is the cosmetic site-wide setting controlled via
  # `Languages.default_language_no_prefix?/0`.
  #
  # The two shapes share one `live_session :phoenix_kit_admin`, so
  # switching locales inside admin stays on the WebSocket
  # (`push_navigate`) — no full-page reload. See `generate_admin_routes/2`
  # in `PhoenixKitWeb.Integration`.
  defp build_admin_path(base_path, url_path, :none), do: "#{base_path}#{url_path}"

  defp build_admin_path(base_path, url_path, locale) when is_binary(locale) do
    if default_locale?(locale) and prefixless_primary?() do
      "#{base_path}#{url_path}"
    else
      "#{base_path}/#{locale}#{url_path}"
    end
  end

  defp build_admin_path(base_path, url_path, _), do: "#{base_path}#{url_path}"

  # Reads the site-wide setting controlled by the Languages admin page.
  # Defers to the canonical boot-safe wrapper on `Languages` so all
  # URL-emission call sites (this module + `Users.Auth`) share one
  # rescue policy.
  defp prefixless_primary?, do: Languages.prefixless_primary_safe?()

  # Check if a path starts with one of the reserved prefixes.
  defp reserved_path?(path) do
    Enum.any?(@reserved_prefixes, &String.starts_with?(path, &1))
  end

  defp determine_locale do
    # Fall back to extracting base from Gettext locale
    # This is only used when locale is not explicitly passed to Routes.path
    # Gettext.get_locale/1 always returns a string
    locale = Gettext.get_locale(PhoenixKitWeb.Gettext)
    DialectMapper.extract_base(locale)
  end

  # Check if the given locale is the default language
  # Default locale doesn't need a prefix in URLs for cleaner URLs
  defp default_locale?(locale) do
    default = get_default_language_base()
    locale == default
  end

  defp get_default_language_base do
    # During mix tasks (like phoenix_kit.install), the database may not have
    # the settings table yet. We detect this by checking if we're in a mix task
    # context and fall back to "en" to avoid database errors.
    if mix_task_context?() do
      "en"
    else
      case Languages.get_default_language() do
        %{code: code} when is_binary(code) -> DialectMapper.extract_base(code)
        _ -> "en"
      end
    end
  rescue
    _ -> "en"
  catch
    # A connection-pool failure EXITS rather than raising, so `rescue` alone
    # never delivered the "path building works without a reachable database"
    # guarantee above. Seen as a flaky suite failure: the settings read is
    # ETS-cached, so a DB-less test only reached the pool on a cache miss —
    # which another test's settings write could cause at any time.
    :exit, _ -> "en"
  end

  # Detect if we're running in a mix task context where the database
  # may not be fully set up yet
  defp mix_task_context? do
    # Check if Mix is loaded and we're not in a running application context
    # The settings cache being unavailable is a reliable indicator
    case Process.get(:phoenix_kit_config_status) do
      nil -> false
      _ -> true
    end
  end

  @doc """
  Returns a locale-aware admin path. For non-primary locales the locale
  segment is always emitted. For the primary locale the shape follows
  the site-wide `default_language_no_prefix` setting
  (`Languages.default_language_no_prefix?/0`): prefixless when the
  setting is on, prefixed when off.

  Both URL shapes resolve at the router level — the admin route macros
  declare `/:locale/admin/*` AND `/admin/*` scopes — so either shape is
  routable. The two shapes share one `live_session :phoenix_kit_admin`,
  so locale switching across them stays on the WebSocket
  (`push_navigate`) without a full-page reload.

  ## Examples

      iex> Routes.admin_path("/admin/users", "uk")
      "/phoenix_kit/uk/admin/users"

      iex> Routes.admin_path("/admin/users", nil)
      "/phoenix_kit/admin/users"

  Primary-locale shape depends on the `default_language_no_prefix`
  setting (not shown as doctests because the result varies with
  runtime state):

      # setting OFF (default)
      Routes.admin_path("/admin/users", "en") #=> "/phoenix_kit/en/admin/users"

      # setting ON
      Routes.admin_path("/admin/users", "en") #=> "/phoenix_kit/admin/users"

  """
  def admin_path(url_path, locale) when is_binary(locale) do
    url_prefix = Config.get_url_prefix()
    base_prefix = if url_prefix == "/", do: "", else: url_prefix

    if default_locale?(locale) and prefixless_primary?() do
      "#{base_prefix}#{url_path}"
    else
      "#{base_prefix}/#{locale}#{url_path}"
    end
  end

  def admin_path(url_path, _locale), do: path(url_path)

  @doc """
  Returns a locale-aware path using locale from assigns.

  This function is specifically designed for use in component templates
  where the locale needs to be passed explicitly via assigns.

  Prefers base locale code for URL generation (current_locale_base),
  falls back to extracting base from full dialect code (current_locale).
  """
  def locale_aware_path(assigns, url_path) do
    # Prefer base code, fall back to extracting from full dialect
    locale =
      assigns[:current_locale_base] ||
        DialectMapper.extract_base(assigns[:current_locale] || @default_locale)

    path(url_path, locale: locale)
  end

  @doc """
  Returns the default locale (base code) from the Languages module.

  Extracts the base code from the default language (e.g., "en-US" becomes "en").
  Falls back to "en" if no default language is configured.

  ## Examples

      iex> Routes.get_default_admin_locale()
      "en"
  """
  def get_default_admin_locale do
    get_default_language_base()
  end

  @doc """
  Returns a full url with preconfigured prefix.

  This function first checks for a configured site URL in Settings,
  then automatically detects the correct URL from the running Phoenix
  application endpoint when possible, falling back to static configuration.
  This ensures that magic links and other email links work correctly in both
  development and production environments, with full control over the base URL
  through the Settings admin panel.
  """
  def url(url_path) do
    base_url = get_base_url_for_emails()
    full_path = path(url_path)

    normalized_base = String.trim_trailing(base_url, "/")
    "#{normalized_base}#{full_path}"
  end

  @doc """
  The bare base URL (scheme + host, no trailing slash), same source `url/1` uses.

  For absolutizing a path that is **already** url-prefixed and locale-prefixed
  (e.g. a notification's `link`, built via `path/1`) — concatenate it onto this
  directly. Do NOT pass such a path to `url/1`, which re-applies `path/1` and
  would double-prefix it.
  """
  @spec base_url() :: String.t()
  def base_url, do: String.trim_trailing(get_base_url_for_emails(), "/")

  # Gets the base URL for email links.
  #
  # Priority:
  # 1. site_url setting from Settings (if configured)
  # 2. Dynamic URL from Phoenix endpoint
  # 3. Static configuration fallback
  #
  # This allows administrators to override the email link URLs through
  # the Settings panel, which is especially useful in production.
  defp get_base_url_for_emails do
    case PhoenixKit.Settings.get_setting("site_url", "") do
      "" ->
        PhoenixKit.Config.get_dynamic_base_url()

      site_url when is_binary(site_url) ->
        site_url
    end
  end

  @doc """
  Gets the base module name for the parent application.

  Reads from :phoenix_kit, :layouts_module config (e.g., MprojectWeb.Layouts -> MprojectWeb).

  ## Examples

      iex> PhoenixKit.Utils.Routes.phoenix_kit_app_base()
      "MprojectWeb"

  """
  @spec phoenix_kit_app_base() :: String.t()
  def phoenix_kit_app_base do
    case PhoenixKit.Config.get(:layouts_module) do
      {:ok, module} when is_atom(module) ->
        module
        |> Module.split()
        # Drop last segment (Layouts)
        |> Enum.slice(0..-2//1)
        |> Module.concat()

      _ ->
        "AppWeb"
    end
  end
end
