defmodule PhoenixKit.Test.ApiReadProbeAdapter do
  @moduledoc """
  A `Plug.Conn.Adapter` for tests that wraps the `Plug.Test` adapter and
  reports every body read to the test process as `{:read_req_body, opts}`.

  `wrap(conn, :pass)` answers reads as `Plug.Test` does, so a test can assert
  that a body was (or, with `refute_received`, was not) read. `wrap(conn,
  :fail)` answers every read with `{:error, :timeout}`, the way an adapter
  does for a closed connection or a read timeout.

  The reads are reported to the process that reads, which for a plug called
  directly in a test is the test process.
  """
  @behaviour Plug.Conn.Adapter

  alias Plug.Adapters.Test.Conn, as: TestAdapter

  @spec wrap(Plug.Conn.t(), :pass | :fail) :: Plug.Conn.t()
  def wrap(%Plug.Conn{adapter: {TestAdapter, inner}} = conn, mode) when mode in [:pass, :fail],
    do: %{conn | adapter: {__MODULE__, {inner, mode}}}

  @impl Plug.Conn.Adapter
  def read_req_body({inner, mode}, opts) do
    send(self(), {:read_req_body, opts})

    case mode do
      :fail ->
        {:error, :timeout}

      :pass ->
        {tag, data, inner} = TestAdapter.read_req_body(inner, opts)
        {tag, data, {inner, mode}}
    end
  end

  @impl Plug.Conn.Adapter
  def send_resp({inner, mode}, status, headers, body) do
    {:ok, sent, inner} = TestAdapter.send_resp(inner, status, headers, body)
    {:ok, sent, {inner, mode}}
  end

  @impl Plug.Conn.Adapter
  def send_file({inner, mode}, status, headers, path, offset, length) do
    {:ok, sent, inner} = TestAdapter.send_file(inner, status, headers, path, offset, length)
    {:ok, sent, {inner, mode}}
  end

  @impl Plug.Conn.Adapter
  def send_chunked({inner, mode}, status, headers) do
    {:ok, sent, inner} = TestAdapter.send_chunked(inner, status, headers)
    {:ok, sent, {inner, mode}}
  end

  @impl Plug.Conn.Adapter
  def chunk({inner, mode}, body) do
    {:ok, sent, inner} = TestAdapter.chunk(inner, body)
    {:ok, sent, {inner, mode}}
  end

  @impl Plug.Conn.Adapter
  def inform({inner, _mode}, status, headers), do: TestAdapter.inform(inner, status, headers)

  @impl Plug.Conn.Adapter
  def upgrade({inner, mode}, protocol, opts) do
    with {:ok, inner} <- TestAdapter.upgrade(inner, protocol, opts), do: {:ok, {inner, mode}}
  end

  @impl Plug.Conn.Adapter
  def push({inner, _mode}, path, headers), do: TestAdapter.push(inner, path, headers)

  @impl Plug.Conn.Adapter
  def get_peer_data({inner, _mode}), do: TestAdapter.get_peer_data(inner)

  @impl Plug.Conn.Adapter
  def get_sock_data({inner, _mode}), do: TestAdapter.get_sock_data(inner)

  @impl Plug.Conn.Adapter
  def get_ssl_data({inner, _mode}), do: TestAdapter.get_ssl_data(inner)

  @impl Plug.Conn.Adapter
  def get_http_protocol({inner, _mode}), do: TestAdapter.get_http_protocol(inner)
end
