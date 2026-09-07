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
    4. **maintenance** — what it did before this plug existed;
    5. the **visitor notice** is injected into the HTML response, the way
       core injects its websocket fix.

  Each step is a no-op when its feature is off. The gate stands in the
  browser pipeline: it protects the site's pages; files a host serves
  outside that pipeline are not behind it.
  """

  import Plug.Conn

  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.WebsiteAccess.{AllowedAddresses, Gate, Notice, Redirect}
  alias PhoenixKitWeb.Plugs.MaintenanceMode

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      # The gate's own pages (prompt, access link, status): not redirected,
      # not gated, not under maintenance (a locked visitor must reach the
      # prompt even while the site is down), no notice. Nothing else is
      # exempt — files served before the router never reach this plug, and
      # a routed path under /assets/ is a page like any other.
      exempt_path?(conn) ->
        conn

      AllowedAddresses.allowed?(IpAddress.client_address(conn)) ->
        conn |> remember_allowed() |> notice() |> maintenance()

      true ->
        # The response callback (robots header, notice) is registered FIRST,
        # so a redirect, a gate bounce or a maintenance page carry the
        # noindex header too; the notice itself only lands on HTML 200s.
        conn
        |> forget_allowed()
        |> notice()
        |> redirect_to_production()
        |> gate()
        |> maintenance()
    end
  end

  # ── Paths that never see the redirect or the gate ──────────────────

  @doc "The gate page's path — the one route the gate itself must let through."
  def gate_path, do: PhoenixKit.Config.get_url_prefix() <> "/access"

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

  # ── Notice ─────────────────────────────────────────────────────────

  defp notice(conn) do
    register_before_send(conn, fn conn ->
      conn
      |> robots_header()
      |> inject_notice()
    end)
  end

  # "Hide from search engines" as a header too, so pages rendered outside
  # the kit's layouts (a host's own templates) carry the directive as well.
  defp robots_header(conn) do
    if Crawlers.no_index_enabled?() do
      put_resp_header(conn, "x-robots-tag", "noindex, nofollow")
    else
      conn
    end
  end

  defp inject_notice(conn) do
    with 200 <- conn.status,
         true <- html_response?(conn),
         html when is_binary(html) <- Notice.html(),
         body when is_binary(body) <- body_string(conn) do
      inject_after_body(conn, body, html)
    else
      _ -> conn
    end
  end

  defp html_response?(conn) do
    content_type = get_resp_header(conn, "content-type") |> List.first() || ""
    encoding = get_resp_header(conn, "content-encoding")
    String.contains?(content_type, "text/html") and encoding == [] and conn.method != "HEAD"
  end

  defp body_string(conn) do
    body = IO.iodata_to_binary(conn.resp_body)
    if String.valid?(body), do: body, else: nil
  rescue
    _ -> nil
  end

  defp inject_after_body(conn, body, html) do
    case Regex.run(~r/<body[^>]*>/i, body, return: :index) do
      [{start, length}] ->
        # Byte offsets from the regex, so a byte split — `String.split_at`
        # counts graphemes and lands late after any non-ASCII `<head>`.
        {before, rest} = :erlang.split_binary(body, start + length)

        # A content-length or etag set upstream describe the old body.
        %{conn | resp_body: before <> html <> rest}
        |> delete_resp_header("content-length")
        |> delete_resp_header("etag")

      _ ->
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
