defmodule PhoenixKit.Integration.Storage.StoreFromUrlTest do
  @moduledoc """
  `Storage.store_from_url/2` and `RemoteFetch.download/2`: the guards with
  the real resolver (which refuses every non-public address), and the
  download itself against a local server reached through the test-only
  `:unsafe_resolver`.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.RemoteFetch
  alias PhoenixKit.Users.Auth

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
         0, 0, 0, 0x1F, 0x15, 0xC4, 0x89, 0, 0, 0, 10, "IDAT", 0x78, 0x9C, 0x63, 0, 1, 0, 0, 5, 0,
         1, 0x0D, 0x0A, 0x2D, 0xB4, 0, 0, 0, 0, "IEND", 0xAE, 0x42, 0x60, 0x82>>

  defmodule Server do
    use Plug.Router

    @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
           0, 0, 0, 0x1F, 0x15, 0xC4, 0x89, 0, 0, 0, 10, "IDAT", 0x78, 0x9C, 0x63, 0, 1, 0, 0, 5,
           0, 1, 0x0D, 0x0A, 0x2D, 0xB4, 0, 0, 0, 0, "IEND", 0xAE, 0x42, 0x60, 0x82>>

    plug(:match)
    plug(:dispatch)

    get "/pic.png" do
      send_resp(conn, 200, @png)
    end

    get("/text.png", do: send_resp(conn, 200, "not an image at all"))
    get("/big", do: send_resp(conn, 200, :binary.copy("x", 5_000)))
    get("/hop", do: conn |> put_resp_header("location", "/pic.png") |> send_resp(302, ""))
    get("/loop", do: conn |> put_resp_header("location", "/loop") |> send_resp(302, ""))
    get("/named/*_rest", do: send_resp(conn, 200, @png))
    match(_, do: send_resp(conn, 404, ""))
  end

  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_from_url_#{n}")

    {:ok, _} =
      Storage.create_bucket(%{
        name: "from-url-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    server = start_supervised!({Bandit, plug: Server, port: 0, ip: :loopback, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
    end)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "from-url-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    local = [
      allow_http: true,
      allowed_ports: [port],
      unsafe_resolver: fn _host -> {:ok, {127, 0, 0, 1}} end
    ]

    %{base: "http://localhost:#{port}", local: local, user: user}
  end

  describe "guards with the real resolver" do
    test "internal and metadata addresses are refused" do
      for url <-
            ~w(https://127.0.0.1/x https://169.254.169.254/latest https://localhost/x https://[::1]/x) do
        assert {:error, :blocked_host} = RemoteFetch.download(url), url
      end
    end

    test "http, credentials and odd ports are refused by default" do
      assert {:error, :scheme_not_allowed} = RemoteFetch.download("http://example.com/a.png")
      assert {:error, :invalid_url} = RemoteFetch.download("https://user:pw@example.com/a.png")
      assert {:error, :port_not_allowed} = RemoteFetch.download("https://example.com:8443/a.png")
      assert {:error, :invalid_url} = RemoteFetch.download("not a url")
    end
  end

  describe "downloading" do
    test "streams the body to a temporary file", %{base: base, local: local} do
      assert {:ok, %{path: path, filename: "pic.png"}} =
               RemoteFetch.download(base <> "/pic.png", local)

      assert File.read!(path) == @png
      File.rm!(path)
    end

    test "cuts off at max_bytes and leaves no file behind", %{base: base, local: local} do
      before = temp_files()

      assert {:error, :too_large} =
               RemoteFetch.download(base <> "/big", local ++ [max_bytes: 1000])

      assert temp_files() == before
    end

    test "follows a redirect, and stops a loop", %{base: base, local: local} do
      assert {:ok, %{path: path}} = RemoteFetch.download(base <> "/hop", local)
      File.rm!(path)
      assert {:error, :too_many_redirects} = RemoteFetch.download(base <> "/loop", local)
    end

    test "the file name is valid UTF-8 and never carries a path separator", ctx do
      assert {:ok, %{path: path, filename: name}} =
               RemoteFetch.download(ctx.base <> "/named/%FF..%2F..%2Fpic.png", ctx.local)

      File.rm(path)
      assert String.valid?(name)
      refute name =~ "/"
      assert name =~ "pic.png"
    end

    test "a non-200 is an error", %{base: base, local: local} do
      assert {:error, {:http_status, 404}} = RemoteFetch.download(base <> "/missing", local)
    end
  end

  describe "store_from_url/2" do
    test "stores what the bytes are", %{base: base, local: local, user: user} do
      assert {:ok, file} =
               Storage.store_from_url(base <> "/pic.png", local ++ [user_uuid: user.uuid])

      assert file.mime_type == "image/png"
      assert file.original_file_name == "pic.png"
    end

    test "refuses bytes that are not an allowed type, whatever the name says", ctx do
      assert {:error, :unsupported_type} =
               Storage.store_from_url(
                 ctx.base <> "/text.png",
                 ctx.local ++ [user_uuid: ctx.user.uuid]
               )
    end
  end

  defp temp_files,
    do: System.tmp_dir!() |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "pk_remote_"))
end
