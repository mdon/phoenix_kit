defmodule PhoenixKit.Modules.Storage.Providers.S3 do
  @moduledoc """
  AWS S3 storage provider.

  Stores files in Amazon S3 buckets using the ExAWS library.
  Supports all S3-compatible services (like Backblaze B2, Cloudflare R2, Tigris).

  Files under 5 MB are uploaded via `put_object` (single request).
  Files at or above 5 MB use multipart upload via `ExAws.S3.upload/4`
  with streaming and concurrent chunk uploads.
  """

  require Logger

  alias ExAws.S3.Upload
  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Encryption

  @behaviour PhoenixKit.Modules.Storage.Provider

  # Files at or above this size use multipart upload
  @multipart_threshold 5 * 1024 * 1024

  @impl true
  def store_file(bucket, source_path, destination_path, opts \\ []) do
    case File.stat(source_path) do
      {:ok, %{size: size}} when size >= @multipart_threshold ->
        multipart_upload(bucket, source_path, destination_path, opts)

      {:ok, _stat} ->
        simple_upload(bucket, source_path, destination_path, opts)

      {:error, reason} ->
        Logger.error("S3 upload: cannot access source file #{source_path}: #{inspect(reason)}")
        {:error, "Cannot access source file: #{inspect(reason)}"}
    end
  rescue
    error ->
      Logger.error("S3 upload exception for #{bucket.name}: #{Exception.message(error)}")
      {:error, "Error storing file to S3: #{inspect(error)}"}
  end

  @impl true
  def retrieve_file(bucket, file_path, destination_path) do
    destination_dir = Path.dirname(destination_path)
    File.mkdir_p!(destination_dir)

    case ExAws.S3.download_file(bucket.bucket_name, file_path, destination_path)
         |> ExAws.request(aws_config(bucket)) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, "Failed to download from S3: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Error retrieving file from S3: #{inspect(error)}"}
  end

  @impl true
  def delete_file(bucket, file_path) do
    case ExAws.S3.delete_object(bucket.bucket_name, file_path)
         |> ExAws.request(aws_config(bucket)) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, "Failed to delete from S3: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Error deleting file from S3: #{inspect(error)}"}
  end

  @impl true
  def file_exists?(bucket, file_path) do
    case ExAws.S3.head_object(bucket.bucket_name, file_path)
         |> ExAws.request(aws_config(bucket)) do
      {:ok, _result} -> true
      {:error, {:http_error, 404, _}} -> false
      {:error, _reason} -> false
    end
  rescue
    _error -> false
  end

  @impl true
  def public_url(bucket, file_path) do
    cond do
      bucket.cdn_url ->
        "#{String.trim_trailing(bucket.cdn_url, "/")}/#{file_path}"

      # A custom S3-compatible endpoint (B2, R2, MinIO, Wasabi…) is where the
      # object is, not amazonaws.com: path style, the way ExAws addresses it.
      endpoint(bucket) ->
        %{scheme: scheme, host: host, port: port} = endpoint(bucket)
        "#{scheme}://#{host}#{port_suffix(scheme, port)}/#{bucket.bucket_name}/#{file_path}"

      true ->
        region = bucket.region || "us-east-1"
        "https://#{bucket.bucket_name}.s3.#{region}.amazonaws.com/#{file_path}"
    end
  end

  @doc """
  A bucket's endpoint, parsed: `%{scheme:, host:, port:}`, or nil for none
  (plain AWS). The one place an endpoint is read, so the host requests go
  to and the host a public URL names cannot disagree. Accepts a bare host
  (`s3.us-west-002.backblazeb2.com`), one with a port, or a full URL; a
  trailing path or slash is dropped, and the scheme defaults to https.
  """
  @spec endpoint(map()) :: %{scheme: String.t(), host: String.t(), port: pos_integer()} | nil
  def endpoint(%{endpoint: endpoint}) when is_binary(endpoint) do
    trimmed = String.trim(endpoint)

    with_scheme =
      if trimmed =~ ~r{\A[a-zA-Z][a-zA-Z0-9+.-]*://}, do: trimmed, else: "https://" <> trimmed

    case URI.parse(with_scheme) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        %{scheme: scheme, host: host, port: port}

      _ ->
        nil
    end
  end

  def endpoint(_bucket), do: nil

  defp port_suffix("https", 443), do: ""
  defp port_suffix("http", 80), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"

  @impl true
  def signed_download_url(bucket, file_path, opts) do
    case resolve_credentials(bucket) do
      {key, secret} when is_binary(key) and key != "" and is_binary(secret) and secret != "" ->
        query_params =
          [
            {"response-content-disposition", Keyword.get(opts, :disposition)},
            {"response-content-type", Keyword.get(opts, :content_type)}
          ]
          |> Enum.reject(fn {_name, value} -> value in [nil, ""] end)

        :s3
        |> ExAws.Config.new(aws_config(bucket))
        |> ExAws.S3.presigned_url(:get, bucket.bucket_name, file_path,
          expires_in: Keyword.get(opts, :expires_in, 3600),
          query_params: query_params
        )

      _ ->
        {:error, :no_credentials}
    end
  rescue
    error -> {:error, "Error signing S3 download URL: #{Exception.message(error)}"}
  end

  @impl true
  def test_connection(bucket) do
    case ExAws.S3.list_objects(bucket.bucket_name, max_keys: 1)
         |> ExAws.request(aws_config(bucket)) do
      {:ok, _result} -> :ok
      {:error, {:http_error, 403, _}} -> {:error, "Access denied - check permissions"}
      {:error, {:http_error, 404, _}} -> {:error, "Bucket not found"}
      {:error, reason} -> {:error, "S3 connection test failed: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Error testing S3 connection: #{inspect(error)}"}
  end

  # Single-request upload for small files (<5 MB).
  # Reads entire file into memory and sends in one PUT request.
  defp simple_upload(bucket, source_path, destination_path, opts) do
    content_type = Keyword.get(opts, :content_type)

    case File.read(source_path) do
      {:ok, file_content} ->
        put_opts =
          [{:acl, Keyword.get(opts, :acl, "private")}] ++
            if(content_type, do: [{:content_type, content_type}], else: [])

        case ExAws.S3.put_object(bucket.bucket_name, destination_path, file_content, put_opts)
             |> ExAws.request(aws_config(bucket)) do
          {:ok, _result} ->
            {:ok, public_url(bucket, destination_path)}

          {:error, reason} ->
            Logger.error("S3 put_object failed for #{bucket.name}: #{inspect(reason)}")
            {:error, "Failed to upload to S3: #{inspect(reason)}"}
        end

      {:error, reason} ->
        Logger.error("S3 upload: cannot read source file #{source_path}: #{inspect(reason)}")
        {:error, "Cannot read source file: #{inspect(reason)}"}
    end
  end

  # Multipart streaming upload for large files (>=5 MB).
  # Streams file in chunks with concurrent part uploads.
  defp multipart_upload(bucket, source_path, destination_path, opts) do
    content_type = Keyword.get(opts, :content_type)

    upload_opts =
      [acl: Keyword.get(opts, :acl, "private"), max_concurrency: 4, timeout: 60_000] ++
        if(content_type, do: [content_type: content_type], else: [])

    case source_path
         |> Upload.stream_file()
         |> ExAws.S3.upload(bucket.bucket_name, destination_path, upload_opts)
         |> ExAws.request(aws_config(bucket)) do
      {:ok, _result} ->
        {:ok, public_url(bucket, destination_path)}

      {:error, reason} ->
        Logger.error("S3 multipart upload failed for #{bucket.name}: #{inspect(reason)}")
        {:error, "Failed multipart upload to S3: #{inspect(reason)}"}
    end
  end

  # Build per-request ExAws config from bucket credentials.
  # Passed to ExAws.request/2 instead of using global Application.put_env.
  defp aws_config(bucket) do
    {access_key_id, secret_access_key} = resolve_credentials(bucket)

    config = [
      access_key_id: access_key_id,
      secret_access_key: secret_access_key,
      region: bucket.region || "us-east-1"
    ]

    case endpoint(bucket) do
      nil ->
        config

      %{scheme: scheme, host: host, port: port} ->
        config ++ [host: host, scheme: scheme <> "://", port: port]
    end
  end

  # Resolves the actual (plaintext) access key id / secret access key for a
  # bucket — the one place this happens, right where the ExAws config needs
  # them. `Bucket.changeset/2` guarantees only one of the two credential
  # sources below is ever set on a saved bucket.
  #
  # Every failure path here returns {nil, nil} / a nil secret rather than
  # raising — a bad/expired credential should fail as an ExAws auth error on
  # the actual request, not crash the caller. Each path logs why first,
  # naming the bucket and the failure REASON only, never a credential value.
  #
  # Public and `@doc false` (not part of the `Provider` behaviour) purely so
  # the test suite can exercise both branches directly, without a real S3
  # endpoint — same rationale as `V174.repair_statements/1`.
  @doc false
  @spec resolve_credentials(PhoenixKit.Modules.Storage.Bucket.t()) ::
          {String.t() | nil, String.t() | nil}
  def resolve_credentials(%{integration_uuid: integration_uuid} = bucket)
      when is_binary(integration_uuid) and integration_uuid != "" do
    case Integrations.get_credentials(integration_uuid) do
      {:ok, creds} ->
        # "access_key"/"secret_key" is the generic key-secret shape
        # `PhoenixKit.Integrations` providers use for AWS-style credentials
        # (see `aws_ses`, and `PhoenixKit.Mailer.swoosh_config_for/1`) — the
        # `object_storage` provider this bucket-side integration_uuid exists
        # for (`PhoenixKit.Integrations.Providers.object_storage/0`, added in
        # a parallel branch) declares the same two field keys.
        access_key = creds["access_key"]
        secret_key = creds["secret_key"]

        if is_binary(access_key) and access_key != "" and is_binary(secret_key) and
             secret_key != "" do
          {access_key, secret_key}
        else
          Logger.error(
            "S3 bucket #{bucket.name}: integration #{integration_uuid} has no " <>
              "access_key/secret_key configured"
          )

          {nil, nil}
        end

      {:error, reason} ->
        Logger.error(
          "S3 bucket #{bucket.name}: failed to resolve credentials from integration " <>
            "#{integration_uuid}: #{inspect(reason)}"
        )

        {nil, nil}
    end
  end

  def resolve_credentials(bucket) do
    secret =
      case Encryption.decrypt_value(bucket.secret_access_key) do
        {:ok, plaintext} ->
          plaintext

        {:error, reason} ->
          Logger.error(
            "S3 bucket #{bucket.name}: failed to decrypt secret_access_key: #{inspect(reason)}"
          )

          nil
      end

    {bucket.access_key_id, secret}
  end
end
