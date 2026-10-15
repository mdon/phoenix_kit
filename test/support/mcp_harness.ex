defmodule PhoenixKit.Test.McpHarness do
  @moduledoc """
  Helpers for the tests of the MCP transport: JSON-RPC messages, a request
  through `PhoenixKit.API.MCP` at plug level, and readers for the answers.

  Built on `PhoenixKit.Test.ApiHarness` (real keys, real settings): import
  both in a test. Core's tests only; this file is under `test/support` and is
  not part of the hex package.
  """

  alias PhoenixKit.API.MCP
  alias PhoenixKit.Test.ApiHarness

  @version "2025-06-18"

  @doc "The protocol revision the default headers announce."
  @spec version() :: String.t()
  def version, do: @version

  @doc "A JSON-RPC request. `params` of `nil` leaves the member out."
  @spec message(String.t(), map() | nil, term()) :: map()
  def message(method, params \\ nil, id \\ 1) do
    base = %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    if params == nil, do: base, else: Map.put(base, "params", params)
  end

  @doc "A JSON-RPC notification: a request without an id."
  @spec notification(String.t(), map() | nil) :: map()
  def notification(method, params \\ nil), do: method |> message(params) |> Map.delete("id")

  @doc "A `tools/call` request."
  @spec call_message(String.t(), map(), term()) :: map()
  def call_message(tool, arguments \\ %{}, id \\ 1),
    do: message("tools/call", %{"name" => tool, "arguments" => arguments}, id)

  @doc "The headers of a well-behaved MCP client."
  @spec default_headers() :: [{String.t(), String.t()}]
  def default_headers, do: [{"accept", "application/json"}, {"mcp-protocol-version", @version}]

  @doc """
  POSTs `body` (a map, as `Plug.Parsers` or `BodyGuard` leave it) to the MCP
  plug of `audience`, at plug level.

  Options: `:token` (bearer), `:ip` (a fresh address by default), `:headers`
  (replaces `default_headers/0`), `:extra_headers` (added to them), `:path`
  (default `"/"`, which is what the plug sees after the router's `forward`).
  """
  @spec post_rpc(:admin | :public, map() | nil, keyword()) :: Plug.Conn.t()
  def post_rpc(audience, body, opts \\ []) do
    headers =
      Keyword.get(opts, :headers, default_headers()) ++ Keyword.get(opts, :extra_headers, [])

    conn_opts = [body: body, headers: headers] ++ Keyword.take(opts, [:token, :ip])

    :post
    |> ApiHarness.api_conn(Keyword.get(opts, :path, "/"), conn_opts)
    |> MCP.call(MCP.init(audience: audience))
  end

  @doc "The `result` member of a sent answer."
  @spec result(Plug.Conn.t()) :: term()
  def result(conn), do: conn |> ApiHarness.json() |> Map.fetch!("result")

  @doc "The `error` member of a sent answer."
  @spec error(Plug.Conn.t()) :: map()
  def error(conn), do: conn |> ApiHarness.json() |> Map.fetch!("error")

  @doc "The names of the tools in a `tools/list` answer."
  @spec tool_names(Plug.Conn.t()) :: [String.t()]
  def tool_names(conn), do: conn |> result() |> Map.fetch!("tools") |> Enum.map(& &1["name"])
end
