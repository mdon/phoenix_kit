defmodule PhoenixKit.WebsiteAccess.Redirect do
  @moduledoc """
  Redirect to production: a visitor's request for a public URL goes to the
  same path on the configured production site.

  Smart on purpose — this site is where the agency works, so nobody who is
  meant to be here is sent away: a logged-in user is not redirected, a path
  under the admin prefix is not (the admin came here to do admin work), the
  gate page and assets are not. Scope narrows it further: `"everyone"`, or
  `"crawlers"` — only search-engine crawlers, by user agent — so a staging
  site can keep its humans and lose its index.

  A 302, never a 301: browsers cache a 301, and this is temporary by
  nature.
  """

  alias PhoenixKit.Settings

  @enabled_key "website_access_redirect_enabled"
  @url_key "website_access_redirect_url"
  @scope_key "website_access_redirect_scope"
  @scopes ~w(everyone crawlers)

  # The usual suspects. A miss here costs one visit by a rare crawler; a
  # false positive would send a person away, so the list is short.
  @crawler_re ~r/googlebot|bingbot|yandex|duckduckbot|baiduspider|slurp|applebot|facebookexternalhit|twitterbot|linkedinbot|petalbot|semrushbot|ahrefsbot|mj12bot|dotbot|crawler|spider/i

  def enabled_key, do: @enabled_key
  def url_key, do: @url_key
  def scope_key, do: @scope_key
  def scopes, do: @scopes

  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get_boolean_setting(@enabled_key, false) and target_url() != nil

  @spec switched_on?() :: boolean()
  def switched_on?, do: Settings.get_boolean_setting(@enabled_key, false)

  @doc "The production URL, normalised without a trailing slash; nil when unset or not http(s)."
  @spec target_url() :: String.t() | nil
  def target_url do
    case target_uri() do
      %URI{} = uri -> URI.to_string(uri)
      nil -> nil
    end
  end

  @doc """
  The production URL parsed and checked: http(s), a host, no userinfo, no
  query, no fragment, no whitespace or control characters; the path (if
  any) is kept as a prefix without its trailing slash. Nil otherwise.
  """
  @spec target_uri() :: URI.t() | nil
  def target_uri do
    raw = Settings.get_setting(@url_key, "") |> String.trim()

    with false <- raw == "" or Regex.match?(~r/[\s\x00-\x1f\x7f]/, raw),
         %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil} = uri
         when scheme in ["http", "https"] and is_binary(host) and host != "" <- URI.parse(raw) do
      %{uri | path: String.trim_trailing(uri.path || "", "/")}
    else
      _ -> nil
    end
  end

  @spec scope() :: String.t()
  def scope do
    case Settings.get_setting(@scope_key, "everyone") do
      s when s in @scopes -> s
      _ -> "everyone"
    end
  end

  @doc "Whether `user_agent` looks like a search-engine crawler."
  @spec crawler?(String.t() | nil) :: boolean()
  def crawler?(user_agent) when is_binary(user_agent), do: Regex.match?(@crawler_re, user_agent)
  def crawler?(_), do: false

  @doc """
  Where `conn` should be sent, or nil when it stays. `logged_in?` is decided
  by the caller (the plug already resolves the session user for maintenance).
  """
  @spec target_for(Plug.Conn.t(), keyword()) :: String.t() | nil
  def target_for(%Plug.Conn{} = conn, opts \\ []) do
    logged_in? = Keyword.get(opts, :logged_in?, false)
    user_agent = conn |> Plug.Conn.get_req_header("user-agent") |> List.first()
    # One read of the target for the whole decision: a setting cleared
    # between two reads must not turn into `nil <> path`.
    target = if switched_on?(), do: target_uri(), else: nil

    cond do
      is_nil(target) -> nil
      logged_in? -> nil
      admin_path?(conn.request_path) -> nil
      scope() == "crawlers" and not crawler?(user_agent) -> nil
      true -> destination(target, conn)
    end
  end

  # The same path and query on the production host, under the target's own
  # path prefix if it has one — built as a URI, never by gluing strings.
  defp destination(%URI{} = target, conn) do
    query = if conn.query_string == "", do: nil, else: conn.query_string
    URI.to_string(%{target | path: target.path <> conn.request_path, query: query})
  end

  defp admin_path?(path) do
    prefix = PhoenixKit.Config.get_url_prefix()
    path == prefix or String.starts_with?(path, prefix <> "/")
  end
end
