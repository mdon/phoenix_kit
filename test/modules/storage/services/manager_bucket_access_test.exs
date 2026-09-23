defmodule PhoenixKit.Modules.Storage.ManagerBucketAccessTest do
  @moduledoc """
  How a remote bucket that holds a file serves it. A public bucket's plain
  object URL answers with the object's stored headers, so a file the app
  would never show in place is handed out as a signed URL that overrides
  them — or proxied when the provider cannot sign one. Never the plain URL.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.Manager

  defmodule Signing do
    def public_url(_bucket, key), do: "https://cdn.example.com/#{key}"

    def signed_download_url(_bucket, key, opts),
      do: {:ok, "https://signed/#{key}?#{opts[:disposition]}"}
  end

  defmodule FailingSigner do
    def public_url(_bucket, key), do: "https://cdn.example.com/#{key}"
    def signed_download_url(_bucket, _key, _opts), do: {:error, :no_credentials}
  end

  defmodule NoSigning do
    def public_url(_bucket, key), do: "https://cdn.example.com/#{key}"
  end

  @download [disposition: "attachment; filename=\"a.zip\"", content_type: "application/zip"]

  test "an inline file on a public bucket gets the plain object URL" do
    assert Manager.bucket_access(%{access_type: "public"}, "k", Signing, nil) ==
             {:redirect, "https://cdn.example.com/k"}
  end

  test "a download on a public bucket gets a signed URL carrying the disposition" do
    assert {:signed_redirect, url} =
             Manager.bucket_access(%{access_type: "public"}, "k", Signing, @download)

    assert url =~ "attachment"
  end

  test "a download is proxied when the provider cannot sign, never given the plain URL" do
    for provider <- [FailingSigner, NoSigning] do
      assert Manager.bucket_access(%{access_type: "public"}, "k", provider, @download) ==
               {:proxy, "k"},
             inspect(provider)
    end
  end

  test "a private bucket is always proxied" do
    for download <- [nil, @download] do
      assert Manager.bucket_access(%{access_type: "private"}, "k", Signing, download) ==
               {:proxy, "k"}
    end
  end
end
