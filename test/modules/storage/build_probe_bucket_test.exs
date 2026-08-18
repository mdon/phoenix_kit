defmodule PhoenixKit.Modules.Storage.BuildProbeBucketTest do
  @moduledoc """
  `Storage.build_probe_bucket/1` — the params-to-struct mapping
  `test_connection/1` probes with before ever touching the network. Split
  out from `resolve_credentials/1` coverage: a bucket bound to an
  `integration_uuid` (no `access_key_id`/`secret_access_key` of its own)
  used to always fail "Test Connection" silently as a missing-credentials
  error, because this mapping dropped `integration_uuid` on the floor.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket

  describe "build_probe_bucket/1" do
    test "threads every credential-relevant field, including integration_uuid" do
      bucket =
        Storage.build_probe_bucket(%{
          "name" => "Prod S3",
          "provider" => "s3",
          "region" => "us-east-1",
          "endpoint" => "s3.example.com",
          "bucket_name" => "my-bucket",
          "access_key_id" => "AKIAEXAMPLE",
          "secret_access_key" => "raw-plaintext",
          "integration_uuid" => "019b669c-3c9d-7256-8ed1-edbc6ae29703"
        })

      assert %Bucket{
               name: "Prod S3",
               provider: "s3",
               region: "us-east-1",
               endpoint: "s3.example.com",
               bucket_name: "my-bucket",
               access_key_id: "AKIAEXAMPLE",
               secret_access_key: "raw-plaintext",
               integration_uuid: "019b669c-3c9d-7256-8ed1-edbc6ae29703"
             } = bucket
    end

    test "falls back to a placeholder name when the params carry none (the LiveView test_connection event never sends one)" do
      bucket = Storage.build_probe_bucket(%{"provider" => "s3"})

      assert bucket.name == "(unsaved bucket)"
      assert bucket.integration_uuid == nil
    end
  end
end
