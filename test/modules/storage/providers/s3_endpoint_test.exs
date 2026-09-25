defmodule PhoenixKit.Modules.Storage.Providers.S3EndpointTest do
  @moduledoc """
  One reading of a bucket's endpoint, for both the requests and the public
  URL: a bare host, a host with a port, and a full URL all name the same
  place, and a custom endpoint's public URL points at it instead of at
  amazonaws.com.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.Providers.S3

  defp bucket(attrs),
    do: Map.merge(%{endpoint: nil, cdn_url: nil, region: nil, bucket_name: "photos"}, attrs)

  test "the forms an endpoint is typed in" do
    assert S3.endpoint(bucket(%{endpoint: "s3.us-west-002.backblazeb2.com"})) ==
             %{scheme: "https", host: "s3.us-west-002.backblazeb2.com", port: 443}

    assert S3.endpoint(bucket(%{endpoint: "https://abc.r2.cloudflarestorage.com/"})) ==
             %{scheme: "https", host: "abc.r2.cloudflarestorage.com", port: 443}

    assert S3.endpoint(bucket(%{endpoint: "http://minio.local:9000"})) ==
             %{scheme: "http", host: "minio.local", port: 9000}

    assert S3.endpoint(bucket(%{endpoint: " minio.local:9000 "})) ==
             %{scheme: "https", host: "minio.local", port: 9000}

    assert S3.endpoint(bucket(%{endpoint: nil})) == nil
    assert S3.endpoint(bucket(%{endpoint: "ftp://nope"})) == nil
  end

  test "a custom endpoint's public URL is on that endpoint, path style" do
    assert S3.public_url(bucket(%{endpoint: "s3.us-west-002.backblazeb2.com"}), "a/b.jpg") ==
             "https://s3.us-west-002.backblazeb2.com/photos/a/b.jpg"

    assert S3.public_url(bucket(%{endpoint: "http://minio.local:9000"}), "a/b.jpg") ==
             "http://minio.local:9000/photos/a/b.jpg"
  end

  test "a CDN URL still wins, and plain AWS is unchanged" do
    assert S3.public_url(bucket(%{cdn_url: "https://cdn.example.com/", endpoint: "x.com"}), "k") ==
             "https://cdn.example.com/k"

    assert S3.public_url(bucket(%{region: "eu-west-1"}), "k") ==
             "https://photos.s3.eu-west-1.amazonaws.com/k"
  end
end
