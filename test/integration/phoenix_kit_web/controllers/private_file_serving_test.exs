defmodule PhoenixKitWeb.PrivateFileServingTest do
  @moduledoc """
  Files in a private library (every user library, V203) are served only
  with a time-window token: the permanent token is refused, an expired one
  is a 403 and never the file, and the response is never kept by a shared
  cache. Files in Media are served exactly as before.

  End to end through `FileController.show/2` from real stored bytes.
  """

  use PhoenixKit.DataCase, async: false

  import Plug.Test

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, Library, URLSigner}
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.FileController

  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "pk_private_serving_#{n}")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "private-serving-#{n}",
        provider: "local",
        endpoint: tmp_root,
        enabled: true,
        priority: 0
      })

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(tmp_root)
    end)

    owner = user!("owner-#{n}")

    {:ok, library} =
      %Library{}
      |> Library.create_user_changeset(%{
        name: "Private #{n}",
        owner_uuid: owner.uuid,
        key_prefix: "lib-test#{n}",
        slug: "private-#{n}",
        is_default: true
      })
      |> Repo.insert()

    %{
      owner: owner,
      library: library,
      private_file: store!(owner, library.uuid, "private bytes #{n}"),
      media_file: store!(owner, nil, "media bytes #{n}")
    }
  end

  defp user!(name) do
    {:ok, user} =
      Auth.register_user(%{"email" => "#{name}@example.com", "password" => "ValidPassword123!"})

    user
  end

  defp store!(owner, library_uuid, content) do
    source = Path.join(System.tmp_dir!(), "pk_private_src_#{System.unique_integer([:positive])}")
    File.write!(source, content)
    checksum = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
    opts = if library_uuid, do: [library_uuid: library_uuid], else: []

    {:ok, file} =
      Storage.store_file_in_buckets(source, "image", owner.uuid, checksum, "jpg", "p.jpg", opts)

    File.rm(source)
    file
  end

  defp show(file, token, extra \\ %{}) do
    params =
      Map.merge(%{"file_uuid" => file.uuid, "variant" => "original", "token" => token}, extra)

    FileController.show(conn(:get, "/"), params)
  end

  defp window_token(file, expires_at \\ URLSigner.window_end(System.os_time(:second))),
    do: URLSigner.private_token(file.uuid, "original", expires_at)

  defp cache_control(conn), do: Plug.Conn.get_resp_header(conn, "cache-control")

  test "a Media file is served with its permanent token, as before", %{media_file: file} do
    conn = show(file, URLSigner.generate_token(file.uuid, "original"))
    assert conn.status == 200

    refute Libraries.private_file?(file)
    assert show(file, window_token(file)).status == 401
  end

  test "a private file refuses its permanent token", %{private_file: file} do
    assert Libraries.private_file?(file)

    conn = show(file, URLSigner.generate_token(file.uuid, "original"))
    assert conn.status == 401
    assert cache_control(conn) == ["private, no-store"]
  end

  test "a private file is served with a time-window token, never to a shared cache",
       %{private_file: file} do
    instance = Storage.get_file_instance_by_name(file.uuid, "original")

    for extra <- [%{}, %{"v" => URLSigner.version(instance)}] do
      conn = show(file, window_token(file), extra)

      assert conn.status == 200
      assert cache_control(conn) == ["private, max-age=3600"]
    end
  end

  test "an expired window is a 403, a forged or misplaced one a 401", %{private_file: file} do
    past = System.os_time(:second) - 60
    assert show(file, window_token(file, past)).status == 403

    # A token for another variant, and a token with its expiry pushed out.
    other_variant = URLSigner.private_token(file.uuid, "thumbnail", URLSigner.window_end(0) + 1)
    assert show(file, other_variant).status == 401

    "w" <> rest = window_token(file)
    [_expiry, mac] = String.split(rest, "-", parts: 2)
    forged = "w" <> Integer.to_string(System.os_time(:second) + 86_400 * 365, 36) <> "-" <> mac
    assert show(file, forged).status == 401
  end

  test "a stale version redirects to a URL with a fresh window token", %{private_file: file} do
    conn = show(file, window_token(file), %{"v" => "0000000000000000"})

    assert conn.status == 302
    [location] = Plug.Conn.get_resp_header(conn, "location")
    [_, token] = Regex.run(~r{/original/([^/?]+)\?}, location)
    assert URLSigner.private_token?(token)
    assert URLSigner.verify_private_token(file.uuid, "original", token) == :ok
  end

  describe "Storage.authorized_url/4" do
    test "the owner gets a working window URL; a stranger nothing", ctx do
      owner = Repo.get!(Auth.User, ctx.owner.uuid)
      url = Storage.authorized_url(Scope.for_user(owner), ctx.private_file, "original")

      [_, token] = Regex.run(~r{/original/([^/?]+)$}, url)
      assert show(ctx.private_file, token).status == 200

      stranger = user!("stranger-#{System.unique_integer([:positive])}")
      refute Storage.authorized_url(Scope.for_user(stranger), ctx.private_file, "original")
    end

    test "a Media file keeps its permanent URL", ctx do
      owner = Repo.get!(Auth.User, ctx.owner.uuid)

      assert Storage.authorized_url(Scope.for_user(owner), ctx.media_file, "original") ==
               URLSigner.signed_url(ctx.media_file.uuid, "original")
    end
  end
end
