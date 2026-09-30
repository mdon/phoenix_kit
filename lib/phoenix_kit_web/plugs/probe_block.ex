defmodule PhoenixKitWeb.Plugs.ProbeBlock do
  @moduledoc """
  Answers scanner probes with a bare `404` before they reach the router.

  Every public site is hit around the clock by scripts looking for leaked
  files and other stacks' admin pages — `/.env`, `/.git/config`,
  `/wp-login.php`, `/phpmyadmin`. A Phoenix app has none of them, but each
  probe still runs the session, CSRF and router work and fills the log with
  404s. This plug ends those requests first, with an empty body.

  It is a path match only: no database, no settings, nothing to configure
  for the common case. Paths under `/.well-known/` always pass (ACME
  challenges, `security.txt`, app links).

  ## Wiring

  In the host's `endpoint.ex`, before `Plug.Static` and the router:

      plug PhoenixKitWeb.Plugs.ProbeBlock

  ## Options

    * `:extra` — more patterns to block: strings (a path prefix, matched
      case-insensitively) or regexes (matched against the path).
    * `:except` — patterns that must pass even though a default matches,
      e.g. `except: [~r/\\.php$/]` for a host that really serves PHP.
    * `:status` — the response status. Default `404`.

  The defaults: dot-files at the root and below (`/.env*`, `/.git`, `/.svn`,
  `/.hg`, `/.aws`, `/.ssh`, `/.DS_Store`, `/.htaccess`…), WordPress paths
  (`wp-admin`, `wp-login.php`, `wp-content`, `wp-includes`, `xmlrpc.php`,
  `wp-config`), any `*.php`, `phpmyadmin`, `cgi-bin`, `/vendor/phpunit`,
  `/actuator` and `/server-status`.
  """

  @behaviour Plug

  import Plug.Conn

  # Pattern SOURCES, not compiled regexes: an endpoint plug's `init/1` runs
  # at compile time and its result is embedded in the module, and compiled
  # regexes cannot be escaped into code on Elixir 1.18 / OTP 28. `call/2`
  # compiles them once per option set and keeps them in :persistent_term.
  @defaults [
    # A dot-segment anywhere in the path, except /.well-known.
    {"(^|/)\\.(?!well-known(/|$))[^/]+", ""},
    {"(^|/)wp-(admin|login|content|includes|config|json)", "i"},
    {"(^|/)xmlrpc\\.php", "i"},
    {"\\.php\\d?$", "i"},
    {"(^|/)(phpmyadmin|pma|myadmin)(/|$)", "i"},
    {"(^|/)cgi-bin(/|$)", "i"},
    {"(^|/)vendor/phpunit", "i"},
    {"^/actuator(/|$)", "i"},
    {"^/server-status(/|$)", "i"}
  ]

  @impl Plug
  def init(opts) do
    %{
      block: @defaults ++ Enum.map(Keyword.get(opts, :extra, []), &source/1),
      except: Enum.map(Keyword.get(opts, :except, []), &source/1),
      status: Keyword.get(opts, :status, 404)
    }
  end

  @impl Plug
  def call(%Plug.Conn{request_path: path} = conn, %{status: status} = config) do
    {block, except} = compiled(config)

    if probe?(path, block, except) do
      conn
      |> send_resp(status, "")
      |> halt()
    else
      conn
    end
  end

  @doc """
  Whether `path` would be blocked by the compiled `block` / `except` lists.
  For tests and for a host checking its own `extra` / `except` patterns.
  """
  @spec probe?(String.t(), [Regex.t()], [Regex.t()]) :: boolean()
  def probe?(path, block, except) do
    not well_known?(path) and Enum.any?(block, &Regex.match?(&1, path)) and
      not Enum.any?(except, &Regex.match?(&1, path))
  end

  defp compiled(%{block: block, except: except}) do
    key = {__MODULE__, :erlang.phash2({block, except})}

    case :persistent_term.get(key, nil) do
      nil ->
        value = {Enum.map(block, &compile/1), Enum.map(except, &compile/1)}
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end

  defp compile({source, flags}), do: Regex.compile!(source, flags)

  # A string is a path prefix (case-insensitive); a regex keeps its own flags.
  defp source(%Regex{source: source, opts: opts}), do: {source, opts_to_flags(opts)}
  defp source(prefix) when is_binary(prefix), do: {"^" <> Regex.escape(prefix), "i"}

  defp opts_to_flags(flags) when is_binary(flags), do: flags

  defp opts_to_flags(opts) when is_list(opts) do
    Enum.map_join(opts, fn
      :caseless -> "i"
      :multiline -> "m"
      :dotall -> "s"
      :extended -> "x"
      :unicode -> "u"
      _ -> ""
    end)
  end

  defp well_known?(path), do: String.starts_with?(path, "/.well-known/") or path == "/.well-known"
end
