defmodule PhoenixKit.Modules.Storage.RemoteFetchHandleTest do
  @moduledoc """
  `RemoteFetch.handle/4` against the event sequences Mint can produce,
  including the one a local test server cannot: trailers after the body.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.RemoteFetch

  defp new_state, do: %{status: nil, headers: [], io: nil, path: nil, bytes: 0}

  defp run(events, max \\ 1_000) do
    ref = make_ref()
    RemoteFetch.handle(Enum.map(events, &put_elem(&1, 1, ref)), ref, new_state(), max)
  end

  test "a plain response is written to one temporary file" do
    assert {:done, {:ok, path}, state} =
             run([
               {:status, nil, 200},
               {:headers, nil, [{"content-type", "image/png"}]},
               {:data, nil, "abc"},
               {:data, nil, "def"},
               {:done, nil}
             ])

    on_exit(fn -> File.rm(path) end)
    File.close(state.io)
    assert File.read!(path) == "abcdef"
  end

  test "trailers after the body do not reopen the file or lose the download" do
    assert {:done, {:ok, path}, state} =
             run([
               {:status, nil, 200},
               {:headers, nil, [{"transfer-encoding", "chunked"}]},
               {:data, nil, "the body"},
               # The trailers: a second :headers event.
               {:headers, nil, [{"x-checksum", "abc"}]},
               {:done, nil}
             ])

    on_exit(fn -> File.rm(path) end)

    # The same file and handle as the body was written to — not a fresh,
    # empty one that replaced it.
    assert state.path == path
    File.close(state.io)
    assert File.read!(path) == "the body"
    assert state.bytes == byte_size("the body")
  end

  test "a redirect or an error status stops before any file is opened" do
    assert {:done, {:redirect, "/next"}, %{io: nil}} =
             run([{:status, nil, 302}, {:headers, nil, [{"location", "/next"}]}])

    assert {:done, {:error, {:http_status, 500}}, %{io: nil}} =
             run([{:status, nil, 500}, {:headers, nil, []}])
  end

  test "a body over the limit is refused while streaming" do
    assert {:done, {:error, :too_large}, state} =
             run([{:status, nil, 200}, {:headers, nil, []}, {:data, nil, "123456"}], 5)

    File.close(state.io)
    File.rm(state.path)
  end
end
