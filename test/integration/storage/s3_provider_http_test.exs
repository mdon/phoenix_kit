defmodule PhoenixKit.Modules.Storage.S3ProviderHTTPTest do
  @moduledoc """
  `Providers.S3` through the real HTTP stack (#882), against a local
  S3-compatible stub served by Bandit: a HEAD answers (it raised a
  `CaseClauseError` under hackney 4 with ExAws's default client, so every
  object read as missing and every download failed), a download reads the
  bytes back, only a 404 means "not there", and the location backfill does
  not record an object as missing when a bucket could not answer.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{LocationCheck, Locations}
  alias PhoenixKit.Modules.Storage.Providers.S3
  alias PhoenixKit.Modules.Storage.Workers.LocationBackfillJob
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  import Ecto.Query

  # A minimal S3: path-style `/<bucket>/<key>`, objects in an Agent. A key
  # starting with "broken" answers 500 to everything.
  defmodule StubS3 do
    @moduledoc false
    import Plug.Conn

    def init(store), do: store

    def call(conn, store) do
      [_bucket | key_parts] = conn.path_info
      key = Enum.join(key_parts, "/")

      cond do
        String.starts_with?(key, "broken") ->
          send_resp(conn, 500, "boom")

        conn.method == "PUT" ->
          {:ok, body, conn} = read_all(conn, "")
          Agent.update(store, &Map.put(&1, key, body))
          conn |> put_resp_header("etag", ~s("etag")) |> send_resp(200, "")

        conn.method in ["HEAD", "GET"] ->
          case Agent.get(store, &Map.get(&1, key)) do
            nil -> send_resp(conn, 404, "")
            body -> object(conn, body)
          end

        true ->
          send_resp(conn, 405, "")
      end
    end

    defp object(%{method: "HEAD"} = conn, body) do
      conn
      |> put_resp_header("content-length", to_string(byte_size(body)))
      |> put_resp_header("etag", ~s("etag"))
      |> send_resp(200, "")
    end

    defp object(conn, body) do
      case get_req_header(conn, "range") do
        ["bytes=" <> range] ->
          [from, to] = range |> String.split("-") |> Enum.map(&String.to_integer/1)
          to = min(to, byte_size(body) - 1)
          send_resp(conn, 206, binary_part(body, from, to - from + 1))

        _ ->
          send_resp(conn, 200, body)
      end
    end

    defp read_all(conn, acc) do
      case read_body(conn) do
        {:ok, chunk, conn} -> {:ok, acc <> chunk, conn}
        {:more, chunk, conn} -> read_all(conn, acc <> chunk)
      end
    end
  end

  setup do
    {:ok, store} = Agent.start_link(fn -> %{} end)

    server =
      start_supervised!(
        {Bandit, plug: {StubS3, store}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "stub-s3-#{System.unique_integer([:positive])}",
        provider: "s3",
        endpoint: "http://127.0.0.1:#{port}",
        bucket_name: "pk",
        region: "us-east-1",
        access_key_id: "test-key",
        secret_access_key: "test-secret",
        enabled: true,
        priority: 0
      })

    %{bucket: bucket, store: store}
  end

  defp source!(content) do
    path = Path.join(System.tmp_dir!(), "pk_s3_http_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "requests go through Req, never ExAws's default client", %{bucket: bucket} do
    assert Keyword.fetch!(S3.aws_config(bucket), :http_client) == ExAws.Request.Req
  end

  test "a HEAD answers: an object that is there exists", ctx do
    Agent.update(ctx.store, &Map.put(&1, "a/b.txt", "hello"))

    assert S3.file_exists?(ctx.bucket, "a/b.txt")
    refute S3.file_exists?(ctx.bucket, "a/missing.txt")
  end

  test "an error other than a 404 is not read as a missing object", ctx do
    assert_raise RuntimeError, ~r/S3 HEAD on bucket .* failed/, fn ->
      S3.file_exists?(ctx.bucket, "broken/x.txt")
    end
  end

  test "a download (which starts with a HEAD) reads the bytes back", ctx do
    assert {:ok, _} = S3.store_file(ctx.bucket, source!("round trip"), "c/d.txt")

    destination = Path.join(System.tmp_dir!(), "pk_s3_http_out_#{System.unique_integer()}")
    on_exit(fn -> File.rm(destination) end)

    assert :ok = S3.retrieve_file(ctx.bucket, "c/d.txt", destination)
    assert File.read!(destination) == "round trip"
  end

  test "the location backfill leaves an instance unchecked when a bucket errors", _ctx do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "s3-http-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    key = "broken/#{System.unique_integer([:positive])}.txt"

    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "b.txt",
        file_name: Path.basename(key),
        file_path: Path.dirname(key),
        mime_type: "text/plain",
        file_type: "document",
        ext: "txt",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        user_uuid: user.uuid
      })

    {:ok, instance} =
      Storage.create_file_instance(%{
        variant_name: "original",
        file_name: key,
        mime_type: "text/plain",
        ext: "txt",
        checksum: "c",
        size: 1,
        processing_status: "completed",
        file_uuid: file.uuid
      })

    totals = LocationBackfillJob.run_pass()

    assert totals[:unsure] >= 1
    refute Repo.exists?(from(c in LocationCheck, where: c.file_instance_uuid == ^instance.uuid))
    refute Locations.known_missing?(key)
  end
end
