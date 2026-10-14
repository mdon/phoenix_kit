defmodule PhoenixKit.API.MCP.Rpc do
  @moduledoc """
  The JSON-RPC 2.0 envelope of the MCP transport: classifying a decoded
  request body and building and sending answers.

  `classify/1` takes `conn.body_params` as `PhoenixKit.API.BodyGuard` (or
  `Plug.Parsers`) left it: a map, where a JSON array or scalar is wrapped as
  `%{"_json" => value}`, and a request with no body at all is
  `%Plug.Conn.Unfetched{}` or `%{}`. It returns:

    * `{:request, id, method, params}`: an object with `"jsonrpc": "2.0"`, a
      string `method` and an `id` that is a string or an integer. `params` is
      whatever the client sent (`nil` when absent);
    * `{:notification, method}`: the same without an `id`. **Whatever the
      method**: a notification gets no answer and must not run anything;
    * `:response`: a `result` or `error` with an `id`, which a client sends
      back to a server request (this server sends none);
    * `{:invalid, id_or_nil, text}`: everything else, among it a batch (MCP
      revision 2025-06-18 removed batching), a bare scalar, an empty object,
      a wrong `jsonrpc`, a `null`, float or boolean `id`. The `id` is echoed
      when the message had a usable one.

  It never raises.
  """

  import Plug.Conn

  @type id :: String.t() | integer()

  @type message ::
          {:request, id(), String.t(), term()}
          | {:notification, String.t()}
          | :response
          | {:invalid, id() | nil, String.t()}

  @codes %{
    parse_error: -32_700,
    invalid_request: -32_600,
    method_not_found: -32_601,
    invalid_params: -32_602,
    internal_error: -32_603
  }

  @doc "The JSON-RPC error code of `name` (`:parse_error`, `:invalid_request`, `:method_not_found`, `:invalid_params`, `:internal_error`)."
  @spec code(atom()) :: integer()
  def code(name), do: Map.fetch!(@codes, name)

  @doc "Classifies a decoded request body, see the moduledoc."
  @spec classify(term()) :: message()
  def classify(%Plug.Conn.Unfetched{}), do: {:invalid, nil, "The request has no JSON body."}

  def classify(%{"_json" => list} = map) when map_size(map) == 1 and is_list(list),
    do: {:invalid, nil, "Batch requests are not supported: send one message per request."}

  def classify(%{"_json" => _value} = map) when map_size(map) == 1,
    do: {:invalid, nil, "A JSON-RPC message must be a JSON object."}

  def classify(%{} = map) when map_size(map) == 0,
    do: {:invalid, nil, "The request body is empty."}

  def classify(%{"jsonrpc" => "2.0"} = map), do: classify_message(map)

  def classify(%{} = map),
    do: {:invalid, valid_id(map), ~s(The "jsonrpc" member must be the string "2.0".)}

  def classify(_other), do: {:invalid, nil, "A JSON-RPC message must be a JSON object."}

  defp classify_message(%{"method" => method} = map) when is_binary(method) do
    case Map.fetch(map, "id") do
      :error ->
        {:notification, method}

      {:ok, id} when is_binary(id) or is_integer(id) ->
        {:request, id, method, Map.get(map, "params")}

      {:ok, _unusable} ->
        {:invalid, nil, "The id must be a string or an integer."}
    end
  end

  defp classify_message(%{"id" => id} = map)
       when (is_binary(id) or is_integer(id)) and
              (is_map_key(map, "result") or is_map_key(map, "error")),
       do: :response

  defp classify_message(map),
    do: {:invalid, valid_id(map), ~s(A message needs a "method" member.)}

  defp valid_id(%{"id" => id}) when is_binary(id) or is_integer(id), do: id
  defp valid_id(_map), do: nil

  @doc "The success envelope."
  @spec result_envelope(id(), map()) :: map()
  def result_envelope(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  @doc "The error envelope. `id` is `nil` when the request had no usable id."
  @spec error_envelope(id() | nil, integer(), String.t()) :: map()
  def error_envelope(id, code, message) when is_integer(code) and is_binary(message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  @doc "Sends `body` as JSON with `status`. Not halted."
  @spec send_json(Plug.Conn.t(), pos_integer(), map()) :: Plug.Conn.t()
  def send_json(conn, status, body) do
    conn
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, JSON.encode!(body))
  end

  @doc """
  Sends a JSON-RPC error with HTTP `status` and halts. `name` is one of the
  atoms of `code/1`.
  """
  @spec send_error(Plug.Conn.t(), pos_integer(), id() | nil, atom(), String.t()) :: Plug.Conn.t()
  def send_error(conn, status, id, name, message) when is_atom(name) do
    conn
    |> send_json(status, error_envelope(id, code(name), message))
    |> halt()
  end

  @doc "`202 Accepted` with no body: the answer to a notification or a response."
  @spec accepted(Plug.Conn.t()) :: Plug.Conn.t()
  def accepted(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(202, "")
  end
end
