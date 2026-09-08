defmodule PhoenixKitWeb.Plugs.WebsiteAccess do
  @moduledoc """
  The website-access features, in the browser pipeline, in this order:

    1. an **allowed address** passes everything below;
    2. **redirect to production** — a public GET/HEAD from a visitor who is
       not logged in and not on an admin path is sent to the same path on the
       production site (bounce the public first: only people who may stay
       ever see a prompt);
    3. the **password gate** — no unlocked session means the gate page and
       nothing else (the gate's own route and the site's assets pass, so the
       page can render and be submitted);
    4. **maintenance** — what it did before this plug existed.

  "Hide from search engines" rides along: every response leaves with the
  `X-Robots-Tag` header while it is on, pages the kit does not render
  included.

  Each step is a no-op when its feature is off. The gate stands in the
  browser pipeline: it protects the site's pages; files a host serves
  outside that pipeline are not behind it.
  """

  import Plug.Conn

  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.WebsiteAccess.{AllowedAddresses, Gate, Redirect}
  alias PhoenixKitWeb.Plugs.MaintenanceMode

  def init(opts), do: opts

  def call(conn, _opts) do
    # Whether this address is on the list is remembered or forgotten on
    # EVERY request, the gate's own pages included, so a LiveView mount
    # always sees the latest verdict.
    allowed? = AllowedAddresses.allowed?(IpAddress.client_address(conn))
    conn = if allowed?, do: remember_allowed(conn), else: forget_allowed(conn)

    cond do
      # The gate's own pages (prompt, access link, status): not redirected,
      # not gated, not under maintenance (a locked visitor must reach the
      # prompt even while the site is down). Nothing else is exempt —
      # files served before the router never reach this plug, and a routed
      # path under /assets/ is a page like any other.
      exempt_path?(conn) ->
        conn

      allowed? ->
        conn |> robots() |> maintenance()

      true ->
        # The robots header is registered FIRST, so a redirect, a gate
        # bounce or a maintenance page carry the noindex directive too.
        conn
        |> robots()
        |> redirect_to_production()
        |> gate()
        |> maintenance()
    end
  end

  # ── Paths that never see the redirect or the gate ──────────────────

  @doc "The gate page's path — the one route the gate itself must let through."
  def gate_path, do: Routes.prefix_base() <> "/access"

  defp exempt_path?(%Plug.Conn{request_path: path}) do
    gate = gate_path()
    path == gate or String.starts_with?(path, gate <> "/")
  end

  @session_allowed :website_access_allowed

  @doc "The session key an allowed address is remembered under (for LiveView mounts)."
  def allowed_session_key, do: @session_allowed

  # An allowed address passes the plug, and its LiveViews need to know: the
  # address is remembered in the session for `on_mount` to check against
  # the list again. NOT a global unlock (panel finding): the first request
  # from anywhere else forgets it, so a session seen once from the office
  # does not stay open from home.
  defp remember_allowed(conn) do
    address = IpAddress.client_address(conn)

    if get_session(conn, @session_allowed) == address,
      do: conn,
      else: put_session(conn, @session_allowed, address)
  end

  defp forget_allowed(conn) do
    if get_session(conn, @session_allowed), do: delete_session(conn, @session_allowed), else: conn
  end

  # ── Redirect ───────────────────────────────────────────────────────

  defp redirect_to_production(%Plug.Conn{halted: true} = conn), do: conn

  defp redirect_to_production(%Plug.Conn{method: method} = conn) when method in ["GET", "HEAD"] do
    if Redirect.switched_on?() do
      case Redirect.target_for(conn, logged_in?: logged_in?(conn)) do
        nil ->
          conn

        url ->
          if same_origin?(conn, url) do
            conn
          else
            conn
            |> put_resp_header("cache-control", "no-store")
            |> put_resp_header("location", url)
            |> send_resp(302, "")
            |> halt()
          end
      end
    else
      conn
    end
  end

  defp redirect_to_production(conn), do: conn

  # A production URL that points back here (same scheme, host and port)
  # would loop. A different port or scheme on the same host is a different
  # site — a dev on :4000 next to a prod on :443, say.
  # A production URL that points back at this host would loop, and a loop
  # is a total outage — so the same host counts as a loop unless BOTH sides
  # name a non-default port and the ports differ (a dev on localhost:4000
  # next to a prod on localhost:4001). Scheme and port as the app sees them
  # are not the visitor's behind a proxy (nginx terminates TLS and talks to
  # :4000), which is why they are not compared on their own.
  defp same_origin?(conn, url) do
    case URI.parse(url) do
      %URI{host: host, port: port, scheme: scheme} when is_binary(host) ->
        same_host? = String.downcase(host) in [String.downcase(conn.host), configured_host()]
        url_explicit? = port != nil and port != URI.default_port(scheme || "http")
        conn_explicit? = conn.port not in [80, 443]

        same_host? and not (url_explicit? and conn_explicit? and port != conn.port)

      _ ->
        false
    end
  end

  # The host this site is configured to live on (the base URL setting), so
  # the loop guard does not rest on the request's Host header alone — a
  # spoofed Host can only skip the courtesy redirect, never the gate.
  defp configured_host do
    case URI.parse(Routes.base_url()) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ── Gate ───────────────────────────────────────────────────────────

  defp gate(%Plug.Conn{halted: true} = conn), do: conn

  defp gate(conn) do
    if Gate.enabled?() do
      case pass(conn) do
        {:ok, conn} ->
          conn

        :locked ->
          conn
          |> put_resp_header("cache-control", "no-store")
          |> put_resp_header("x-robots-tag", "noindex, nofollow")
          |> Phoenix.Controller.redirect(to: gate_path() <> return_query(conn))
          |> halt()
      end
    else
      conn
    end
  end

  @doc """
  Whether `conn` may pass the gate: its session is unlocked, or it belongs
  to a logged-in user and logged-in users pass (then the session is stamped
  as unlocked, so the next request costs nothing).
  """
  @spec pass(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | :locked
  def pass(conn) do
    cond do
      Gate.unlocked?(conn) -> {:ok, conn}
      Gate.users_pass?() and logged_in?(conn) -> {:ok, Gate.unlock(conn)}
      AllowedAddresses.allowed?(IpAddress.client_address(conn)) -> {:ok, conn}
      true -> :locked
    end
  end

  # After the password, back to where the visitor was going — a path on this
  # site only.
  defp return_query(%Plug.Conn{method: "GET", request_path: "/" <> _ = path} = conn)
       when path != "" do
    to = if conn.query_string == "", do: path, else: path <> "?" <> conn.query_string
    "?" <> URI.encode_query(%{"to" => to})
  end

  defp return_query(_conn), do: ""

  # ── Maintenance ────────────────────────────────────────────────────

  defp maintenance(%Plug.Conn{halted: true} = conn), do: conn
  defp maintenance(conn), do: MaintenanceMode.call(conn, [])

  # ── Hide from search engines ───────────────────────────────────────

  defp robots(conn), do: register_before_send(conn, &robots_header/1)

  # As a header and not only in the page, so pages rendered outside the
  # kit's layouts (a host's own templates) carry the directive as well.
  defp robots_header(conn) do
    if Crawlers.no_index_enabled?() do
      put_resp_header(conn, "x-robots-tag", "noindex, nofollow")
    else
      conn
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  # The same reading the maintenance plug makes: a session token that outlived
  # a deactivation must not count.
  defp logged_in?(conn) do
    case get_session(conn, :user_token) do
      nil -> false
      token -> token |> Auth.get_user_by_session_token() |> Auth.ensure_active_user() != nil
    end
  end
end
