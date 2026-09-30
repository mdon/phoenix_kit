defmodule PhoenixKit.Integration.Storage.URLSignerVerifyUrlTest do
  @moduledoc """
  `URLSigner.verify_url/2` applies the file route's own parsing and token
  rule, so an app handed one of the kit's file URLs can tell a real one
  from a forged or tampered one without splitting it by hand.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Library, URLSigner}
  alias PhoenixKit.Users.Auth

  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_verify_url_#{n}")

    {:ok, _} =
      Storage.create_bucket(%{
        name: "verify-url-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
    end)

    {:ok, owner} =
      Auth.register_user(%{
        "email" => "verify-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, library} =
      %Library{}
      |> Library.create_user_changeset(%{
        name: "Private #{n}",
        owner_uuid: owner.uuid,
        key_prefix: "verify#{n}",
        slug: "verify-#{n}",
        is_default: true
      })
      |> Repo.insert()

    %{
      public: store!(owner, nil, "public #{n}"),
      private: store!(owner, library.uuid, "private #{n}")
    }
  end

  defp store!(owner, library_uuid, content) do
    source = Path.join(System.tmp_dir!(), "pk_verify_src_#{System.unique_integer([:positive])}")
    File.write!(source, content)
    checksum = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
    opts = if library_uuid, do: [library_uuid: library_uuid], else: []

    {:ok, file} =
      Storage.store_file_in_buckets(
        source,
        "document",
        owner.uuid,
        checksum,
        "txt",
        "a.txt",
        opts
      )

    File.rm(source)
    file
  end

  test "a URL the app minted verifies, with or without host, prefix and version", %{public: file} do
    path = URLSigner.signed_url(file.uuid, "original")
    uuid = file.uuid

    assert {:ok, %{uuid: ^uuid, variant: "original", version: nil}} = URLSigner.verify_url(path)
    assert {:ok, _} = URLSigner.verify_url("https://example.com" <> path)

    assert {:ok, _} =
             URLSigner.verify_url("/phoenix_kit/et/file/#{uuid}/original/" <> token(path))

    assert {:ok, %{version: "abc"}} = URLSigner.verify_url(path <> "?v=abc")
  end

  test "a tampered token, variant or uuid is refused", %{public: file} do
    path = URLSigner.signed_url(file.uuid, "original")

    assert {:error, :invalid_token} =
             URLSigner.verify_url(String.replace(path, token(path), "zzzz"))

    assert {:error, :invalid_token} =
             URLSigner.verify_url(String.replace(path, "/original/", "/large/"))

    assert {:error, :not_found} =
             URLSigner.verify_url(String.replace(path, file.uuid, Ecto.UUID.generate()))
  end

  test "a private file takes its window token, never its permanent one", %{private: file} do
    assert {:ok, _} =
             URLSigner.verify_url(URLSigner.signed_url(file.uuid, "original", private: true))

    assert {:error, :invalid_token} =
             URLSigner.verify_url(URLSigner.signed_url(file.uuid, "original"))
  end

  test "anything that is not a file URL is malformed" do
    for junk <- ["", "/", "/file/not-a-uuid/original/abcd", "/users/log-in", "file", nil, 42] do
      assert {:error, :malformed} = URLSigner.verify_url(junk)
    end
  end

  defp token(path), do: path |> String.split("/") |> List.last()
end
