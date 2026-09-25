defmodule PhoenixKit.Modules.Storage.BucketEndpointTest do
  @moduledoc """
  A cloud bucket's endpoint is checked when it is saved: one `S3.endpoint/1`
  cannot use is a form error, not a bucket that silently talks to AWS. A
  local bucket's endpoint is a filesystem path and is not checked. `signed`
  is an access type the changeset keeps.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.Bucket

  defp changeset(attrs),
    do:
      Bucket.changeset(
        %Bucket{},
        Map.merge(
          %{
            "name" => "b",
            "provider" => "s3",
            "bucket_name" => "photos",
            "access_key_id" => "k",
            "secret_access_key" => "s"
          },
          attrs
        )
      )

  test "an unusable endpoint is a form error" do
    assert changeset(%{"endpoint" => "http://minio.local:9000/s3"}).errors[:endpoint]
    refute changeset(%{"endpoint" => "http://minio.local:9000"}).errors[:endpoint]
    refute changeset(%{"endpoint" => ""}).errors[:endpoint]
  end

  test "a local bucket's endpoint is a path, not checked" do
    cs =
      Bucket.changeset(%Bucket{}, %{
        "name" => "l",
        "provider" => "local",
        "endpoint" => "priv/media"
      })

    refute cs.errors[:endpoint]
  end

  test "signed is kept" do
    assert Ecto.Changeset.get_field(changeset(%{"access_type" => "signed"}), :access_type) ==
             "signed"
  end
end
