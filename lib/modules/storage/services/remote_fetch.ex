defmodule PhoenixKit.Modules.Storage.RemoteFetch do
  @moduledoc """
  Downloads a user-supplied URL to a temporary file without letting it reach
  the server's own network.

  A URL is a request for the server to connect somewhere, and the
  "somewhere" is the attacker's to choose: `http://169.254.169.254/` (cloud
  credentials), `http://localhost:5432/`, a name that resolves to an internal
  address, or one that resolves to a public address when checked and an
  internal one a moment later (DNS rebinding). So:

    * only `https` by default (`allow_http: true` to allow plain http), no
      credentials in the URL, ports 80/443 unless `allowed_ports:` says so;
    * the host is resolved once, **every** address it resolves to must be
      public (`PhoenixKit.Utils.PublicAddress`), and the connection is made
      to the address that was checked — with the original name for `Host`,
      SNI and certificate verification (Mint's `:hostname`), so nothing
      resolves the name again between the check and the connect;
    * redirects are followed by hand (at most `max_redirects`, default 3),
      each hop checked again, and an https URL never redirects to http;
    * the body is streamed to a temporary file and cut off at `max_bytes`
      (default 25 MB) whatever `Content-Length` claims, within one overall
      `timeout` (default 15 s).

  `download/2` returns `{:ok, %{path: temp_path, filename: name, url: final_url}}`;
  the caller removes the temporary file. What the bytes ARE is decided later,
  by sniffing them (`Storage.store_from_url/2`), never from the response's
  `Content-Type`.
  """

  alias PhoenixKit.Utils.PublicAddress

  @default_max_bytes 25_000_000
  @default_timeout 15_000
  @default_redirects 3

  @type reason ::
          :invalid_url
          | :scheme_not_allowed
          | :port_not_allowed
          | :blocked_host
          | :nxdomain
          | :too_many_redirects
          | :too_large
          | :timeout
          | {:http_status, pos_integer()}
          | {:connect_failed, term()}

  @spec download(String.t(), keyword()) ::
          {:ok, %{path: String.t(), filename: String.t(), url: String.t()}}
          | {:error, reason()}
  def download(url, opts \\ []) when is_binary(url) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, @default_timeout)
    fetch(url, opts, Keyword.get(opts, :max_redirects, @default_redirects), deadline, nil)
  end

  defp fetch(url, opts, redirects_left, deadline, previous_scheme) do
    with {:ok, uri} <- validate(url, opts, previous_scheme),
         {:ok, ip} <- resolve(uri.host, opts),
         {:ok, conn} <- connect(uri, ip, deadline) do
      case request(conn, uri, opts, deadline) do
        {:redirect, location} when redirects_left > 0 ->
          next = uri |> URI.merge(location) |> URI.to_string()
          fetch(next, opts, redirects_left - 1, deadline, uri.scheme)

        {:redirect, _location} ->
          {:error, :too_many_redirects}

        {:ok, path} ->
          {:ok, %{path: path, filename: filename(uri), url: URI.to_string(uri)}}

        {:error, _} = error ->
          error
      end
    end
  end

  defp validate(url, opts, previous_scheme) do
    uri = URI.parse(url)
    allowed_schemes = if opts[:allow_http], do: ["https", "http"], else: ["https"]
    allowed_ports = Keyword.get(opts, :allowed_ports, [80, 443])

    cond do
      uri.host in [nil, ""] or uri.scheme in [nil, ""] -> {:error, :invalid_url}
      uri.userinfo != nil -> {:error, :invalid_url}
      uri.scheme not in allowed_schemes -> {:error, :scheme_not_allowed}
      previous_scheme == "https" and uri.scheme != "https" -> {:error, :scheme_not_allowed}
      uri.port not in allowed_ports -> {:error, :port_not_allowed}
      true -> {:ok, uri}
    end
  end

  # `:unsafe_resolver` exists for this module's own tests (a local server on
  # 127.0.0.1); nothing else should pass it.
  defp resolve(host, opts) do
    case opts[:unsafe_resolver] do
      fun when is_function(fun, 1) -> fun.(host)
      _ -> PublicAddress.resolve_public(host)
    end
  end

  defp connect(uri, ip, deadline) do
    scheme = if uri.scheme == "https", do: :https, else: :http

    case Mint.HTTP.connect(scheme, ip, uri.port,
           hostname: uri.host,
           mode: :passive,
           transport_opts: [timeout: remaining(deadline)]
         ) do
      {:ok, conn} -> {:ok, conn}
      {:error, error} -> {:error, {:connect_failed, error}}
    end
  end

  defp request(conn, uri, opts, deadline) do
    path =
      case {uri.path, uri.query} do
        {p, nil} when p in [nil, ""] -> "/"
        {p, nil} -> p
        {p, q} -> if(p in [nil, ""], do: "/", else: p) <> "?" <> q
      end

    headers = [{"user-agent", "PhoenixKit"}, {"accept", "*/*"}]

    case Mint.HTTP.request(conn, "GET", path, headers, nil) do
      {:ok, conn, ref} ->
        state = %{status: nil, headers: [], io: nil, path: nil, bytes: 0}

        result =
          receive_loop(
            conn,
            ref,
            state,
            Keyword.get(opts, :max_bytes, @default_max_bytes),
            deadline
          )

        result

      {:error, conn, error} ->
        Mint.HTTP.close(conn)
        {:error, {:connect_failed, error}}
    end
  end

  defp receive_loop(conn, ref, state, max_bytes, deadline) do
    case remaining(deadline) do
      0 ->
        finish(conn, state, {:error, :timeout})

      timeout ->
        case Mint.HTTP.recv(conn, 0, timeout) do
          {:ok, conn, responses} ->
            case handle(responses, ref, state, max_bytes) do
              {:cont, state} -> receive_loop(conn, ref, state, max_bytes, deadline)
              {:done, result, state} -> finish(conn, state, result)
            end

          {:error, conn, %Mint.TransportError{reason: :timeout}, _} ->
            finish(conn, state, {:error, :timeout})

          {:error, conn, error, _} ->
            finish(conn, state, {:error, {:connect_failed, error}})
        end
    end
  end

  defp handle([], _ref, state, _max), do: {:cont, state}

  defp handle([{:status, ref, status} | rest], ref, state, max),
    do: handle(rest, ref, %{state | status: status}, max)

  defp handle([{:headers, ref, headers} | rest], ref, %{status: status} = state, max) do
    state = %{state | headers: headers}

    cond do
      status in [301, 302, 303, 307, 308] ->
        case header(headers, "location") do
          nil -> {:done, {:error, {:http_status, status}}, state}
          location -> {:done, {:redirect, location}, state}
        end

      status != 200 ->
        {:done, {:error, {:http_status, status}}, state}

      too_long?(headers, max) ->
        {:done, {:error, :too_large}, state}

      true ->
        path = temp_path()
        {:ok, io} = File.open(path, [:write, :binary])
        handle(rest, ref, %{state | io: io, path: path}, max)
    end
  end

  defp handle([{:data, ref, data} | rest], ref, %{io: io} = state, max) when io != nil do
    bytes = state.bytes + byte_size(data)

    if bytes > max do
      {:done, {:error, :too_large}, %{state | bytes: bytes}}
    else
      :ok = IO.binwrite(io, data)
      handle(rest, ref, %{state | bytes: bytes}, max)
    end
  end

  defp handle([{:done, ref} | _rest], ref, %{path: path} = state, _max) when path != nil,
    do: {:done, {:ok, path}, state}

  defp handle([_other | rest], ref, state, max), do: handle(rest, ref, state, max)

  # Closes the connection and the file; a temporary file only survives a
  # successful download.
  defp finish(conn, state, result) do
    Mint.HTTP.close(conn)
    if state.io, do: File.close(state.io)

    case result do
      {:ok, _path} -> :ok
      _ -> if state.path, do: File.rm(state.path)
    end

    result
  end

  defp too_long?(headers, max) do
    case header(headers, "content-length") do
      nil ->
        false

      value ->
        case Integer.parse(value) do
          {n, _} -> n > max
          :error -> false
        end
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} -> if String.downcase(key) == name, do: value end)
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp filename(uri) do
    case uri.path |> to_string() |> Path.basename() do
      "" -> "download"
      "/" -> "download"
      name -> URI.decode(name)
    end
  end

  defp temp_path do
    Path.join(System.tmp_dir!(), "pk_remote_#{System.unique_integer([:positive])}")
  end
end
