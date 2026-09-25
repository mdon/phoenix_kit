defmodule PhoenixKitWeb.TrashedFileCacheTest do
  @moduledoc """
  A trashed file's response must never be kept by a shared cache (review of
  PR #847). Since #847 one URL answers differently by caller — the bytes to a
  "media" holder, a 404 to everyone else — but the URL is the same for every
  caller (the token does not name the user). An authorized response marked
  `public` let a CDN keep the holder's copy and serve it to anyone asking for
  that URL; opening the Trash tab alone fetches every trashed thumbnail.

  Served end to end through `FileController.show/2` from real stored bytes,
  since the headers are only written once a variant is actually found.
  """

  use PhoenixKit.DataCase, async: false

  import Plug.Test

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitWeb.FileController

  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "pk_trashed_cache_#{n}")
    source = Path.join(System.tmp_dir!(), "pk_trashed_cache_src_#{n}.jpg")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "trashed-cache-test-#{n}",
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
      File.rm(source)
    end)

    owner = user!("owner-#{n}")
    holder = user!("holder-#{n}")
    {:ok, _} = Permissions.grant_permission(Roles.get_role_by_name("User").uuid, "media")

    # Any bytes will do: `show/2` serves the stored original as it is.
    File.write!(source, "stored bytes #{n}")
    checksum = :sha256 |> :crypto.hash(File.read!(source)) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(source, "image", owner.uuid, checksum, "jpg", "photo.jpg")

    %{stored: file, holder: Repo.get!(Auth.User, holder.uuid)}
  end

  defp user!(name) do
    {:ok, user} =
      Auth.register_user(%{"email" => "#{name}@example.com", "password" => "ValidPassword123!"})

    user
  end

  defp request(file, user, opts) do
    instance = Storage.get_file_instance_by_name(file.uuid, "original")

    params =
      %{
        "file_uuid" => file.uuid,
        "variant" => "original",
        "token" => URLSigner.generate_token(file.uuid, "original")
      }
      |> then(&if(opts[:versioned], do: Map.put(&1, "v", URLSigner.version(instance)), else: &1))

    conn =
      conn(:get, "/")
      |> Plug.Conn.assign(:phoenix_kit_current_user, user)
      |> then(fn conn ->
        if opts[:if_none_match],
          do: Plug.Conn.put_req_header(conn, "if-none-match", ~s("#{instance.checksum}")),
          else: conn
      end)

    FileController.show(conn, params)
  end

  defp cache_control(conn), do: Plug.Conn.get_resp_header(conn, "cache-control")

  test "control: an active file's versioned URL is still cached for good", %{stored: file} do
    conn = request(file, nil, versioned: true)

    assert conn.status == 200
    assert cache_control(conn) == ["public, max-age=31536000, immutable"]
  end

  test "a trashed file served to a media holder is private, never shared", ctx do
    {:ok, trashed} = Storage.trash_file(ctx.stored)

    for versioned <- [true, false] do
      conn = request(trashed, ctx.holder, versioned: versioned)

      assert conn.status == 200, "versioned: #{versioned}"
      assert cache_control(conn) == ["private, no-store"], "versioned: #{versioned}"
    end
  end

  test "a conditional request for a trashed file stays private too", ctx do
    {:ok, trashed} = Storage.trash_file(ctx.stored)
    conn = request(trashed, ctx.holder, versioned: true, if_none_match: true)

    assert conn.status == 304
    assert cache_control(conn) == ["private, no-store"]
  end

  test "a trashed file refused to everyone else is not a cacheable 404", ctx do
    {:ok, trashed} = Storage.trash_file(ctx.stored)
    conn = request(trashed, nil, versioned: true)

    assert conn.status == 404
    assert cache_control(conn) == ["private, no-store"]
  end

  test "a trashed file's tile manifest is a private 404, not a public tile", ctx do
    {:ok, _} = Storage.set_tile_generation(true)
    {:ok, trashed} = Storage.trash_file(ctx.stored)
    token = URLSigner.generate_token(trashed.uuid, "dzi")

    conn =
      conn(:get, "/")
      |> FileController.serve_manifest(%{
        "token" => token,
        "dzi_filename" => "#{trashed.uuid}.dzi"
      })

    assert conn.status == 404
    assert cache_control(conn) == ["private, no-store"]
  end

  test "restoring the file restores its ordinary caching", ctx do
    {:ok, trashed} = Storage.trash_file(ctx.stored)
    {:ok, restored} = Storage.restore_file(trashed)

    conn = request(restored, nil, versioned: true)

    assert conn.status == 200
    assert cache_control(conn) == ["public, max-age=31536000, immutable"]
  end

  # Review of #847: every trashed thumbnail rebuilt a scope (a role query and a
  # permission load). A Trash tab's burst now computes it once per user and
  # active role, for a few seconds.
  describe "authorize_trashed_read/1 with the access cache running" do
    setup do
      start_supervised!({PhoenixKit.Cache.Registry, []})
      start_supervised!({PhoenixKit.Cache, name: :trashed_file_access, ttl: 5_000})
      :ok
    end

    test "answers from the cache within its lifetime", ctx do
      assert FileController.authorize_trashed_read(ctx.holder)

      # Revoked after the first answer: the cached one stands until it
      # expires — which is exactly what makes a thumbnail burst one lookup.
      role = Roles.get_role_by_name("User")
      :ok = revoke!(role.uuid, "media")

      assert FileController.authorize_trashed_read(ctx.holder)
      # A fresh computation already says no.
      refute ctx.holder |> Repo.reload!() |> Scope.for_user() |> Scope.has_module_access?("media")
    end

    test "never lends one user's answer to another", ctx do
      assert FileController.authorize_trashed_read(ctx.holder)

      role = Roles.get_role_by_name("User")
      :ok = revoke!(role.uuid, "media")
      stranger = user!("stranger-#{System.unique_integer([:positive])}")

      refute FileController.authorize_trashed_read(stranger)
    end

    test "an anonymous caller is refused and never cached" do
      refute FileController.authorize_trashed_read(nil)
    end
  end

  defp revoke!(role_uuid, key), do: :ok = Permissions.revoke_permission(role_uuid, key)

  describe "cache_mode/3" do
    test "a trashed file is :private whatever the version or freshness" do
      for freshness <- [:exact, :pending], requested <- [nil, "0123456789abcdef"] do
        assert FileController.cache_mode(%{status: "trashed"}, freshness, requested) == :private
      end
    end

    test "an active file is unchanged" do
      assert FileController.cache_mode(%{status: "active"}, :exact, "0123456789abcdef") ==
               :immutable

      assert FileController.cache_mode(%{status: "active", edit_revision: 0}, :exact, nil) ==
               :day
    end
  end
end
