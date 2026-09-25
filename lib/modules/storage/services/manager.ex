defmodule PhoenixKit.Modules.Storage.Manager do
  @moduledoc """
  Storage manager for handling file operations with redundancy and failover.

  This module coordinates file storage across multiple buckets with automatic
  redundancy, failover, and variant generation.

  ## Where an object is read from (V204)

  Reads, existence checks, public URLs and serving go to the buckets the
  object's location rows name first (`PhoenixKit.Modules.Storage.Locations`),
  in the usual order: local buckets, then by priority. Only when none of
  them has it are the other enabled buckets tried, and a bucket found to
  hold it that way is recorded as a location. Writes still pick buckets by
  priority and redundancy; deletes still remove an unreferenced key from
  every enabled bucket.
  """

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Locations
  alias PhoenixKit.Modules.Storage.ProviderRegistry
  alias PhoenixKit.Modules.Storage.Providers.Local
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate

  # Cache TTL for bucket list (5 minutes)
  @buckets_cache_ttl 300_000

  @doc """
  Stores a file across multiple buckets based on redundancy settings.

  ## Options

  - `:redundancy_copies` - Number of copies to store (default: from settings)
  - `:priority_buckets` - List of specific bucket IDs to use (default: auto-select)
  - `:force_bucket_ids` - List of specific bucket IDs to use (overrides priority_buckets)
  - `:generate_variants` - Whether to generate variants (default: from settings)

  ## Returns

  - `{:ok, file_result}` - File stored successfully with locations
  - `{:error, reason}` - Failed to store file
  """
  def store_file(source_path, opts \\ []) do
    # Get redundancy settings
    redundancy_copies = Keyword.get(opts, :redundancy_copies, get_redundancy_copies())
    force_bucket_ids = Keyword.get(opts, :force_bucket_ids, [])
    priority_buckets = Keyword.get(opts, :priority_buckets, [])
    _generate_variants = Keyword.get(opts, :generate_variants, get_auto_generate_variants())

    # `force_bucket_ids` are exactly the buckets to write to (a variant goes
    # where its original is): every one that is enabled, in the order given.
    # They used to be capped at the redundancy setting and put in enabled-
    # bucket order, so a variant could miss a bucket its original is in.
    buckets =
      if Enum.empty?(force_bucket_ids),
        do: select_buckets_for_storage(redundancy_copies, priority_buckets),
        else: forced_buckets(force_bucket_ids)

    if Enum.empty?(buckets) do
      {:error, "No available storage buckets"}
    else
      # Store file across selected buckets
      store_across_buckets(source_path, buckets, opts)
    end
  rescue
    error -> {:error, "Error storing file: #{inspect(error)}"}
  end

  @doc """
  Retrieves a file from storage with failover.

  Tries each bucket in priority order until the file is found.
  """
  def retrieve_file(file_path, opts \\ []) do
    {located, fallback} = read_order(file_path, Keyword.get(opts, :priority_buckets, []))

    case retrieve_with_failover(file_path, located, opts) do
      {:ok, path, _bucket} ->
        {:ok, path}

      {:error, _} ->
        case retrieve_with_failover(file_path, fallback, opts) do
          {:ok, path, bucket} ->
            Locations.record(file_path, bucket.uuid)
            {:ok, path}

          error ->
            error
        end
    end
  end

  @doc """
  Deletes a file from all storage buckets.
  """
  def delete_file(file_path, opts \\ []) do
    priority_buckets = Keyword.get(opts, :priority_buckets, [])
    buckets = select_buckets_for_retrieval(priority_buckets)

    results =
      buckets
      |> Enum.map(fn bucket ->
        provider = get_provider_for_bucket(bucket)
        provider.delete_file(bucket, file_path)
      end)

    # Return success if at least one deletion succeeded
    if Enum.any?(results, &(&1 == :ok)) do
      :ok
    else
      {:error, "Failed to delete file from all buckets"}
    end
  end

  @doc """
  Checks if a file exists in any storage bucket.
  """
  def file_exists?(file_path, opts \\ []) do
    {located, fallback} = read_order(file_path, Keyword.get(opts, :priority_buckets, []))

    holds? = fn bucket -> bucket_holds?(bucket, file_path) end

    Enum.any?(located, holds?) or
      case Enum.find(fallback, holds?) do
        nil ->
          false

        bucket ->
          Locations.record(file_path, bucket.uuid)
          true
      end
  end

  @doc """
  Gets a public URL for a file from the highest priority bucket that has it.
  """
  def public_url(file_path, opts \\ []) do
    {located, fallback} = read_order(file_path, Keyword.get(opts, :priority_buckets, []))

    url_from = fn bucket, record? ->
      # Only a public bucket hands out a plain object URL: a private or
      # signed one answers it with a denial, so it is not a URL to give out.
      if public_bucket?(bucket) and bucket_holds?(bucket, file_path) do
        if record?, do: Locations.record(file_path, bucket.uuid)
        get_provider_for_bucket(bucket).public_url(bucket, file_path)
      end
    end

    Enum.find_value(located, &url_from.(&1, false)) ||
      Enum.find_value(fallback, &url_from.(&1, true))
  end

  @doc """
  Replicates a file to specific target buckets.

  Retrieves the file from any available bucket, then stores it to
  each target bucket. Returns the list of bucket UUIDs that succeeded.
  """
  def replicate_to_buckets(file_path, target_buckets, opts \\ []) do
    # First retrieve the file to a temp location
    temp_path = generate_temp_path() <> Path.extname(file_path)

    case retrieve_file(file_path, destination_path: temp_path) do
      {:ok, local_path} ->
        try do
          store_across_buckets(local_path, target_buckets, [{:path_prefix, file_path} | opts])
        after
          File.rm(local_path)
        end

      {:error, reason} ->
        {:error, "Cannot retrieve source file for replication: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Replication failed: #{inspect(error)}"}
  end

  # Private functions

  defp select_buckets_for_storage(redundancy_copies, priority_buckets) do
    if Enum.empty?(priority_buckets) do
      # Get fresh bucket list from database (don't use cache for selection)
      # This ensures we get the current state and can shuffle properly
      all_buckets = Storage.list_enabled_buckets()

      # Separate buckets by priority
      {auto_priority_buckets, fixed_priority_buckets} =
        Enum.split_with(all_buckets, &(&1.priority == 0))

      # Shuffle auto-priority buckets (priority = 0) for random distribution
      # Fixed priority buckets are deterministic
      shuffled_auto = Enum.shuffle(auto_priority_buckets)

      # Combine: fixed priority buckets first (sorted), then shuffled auto-priority
      (Enum.sort_by(fixed_priority_buckets, & &1.priority) ++ shuffled_auto)
      |> Enum.take(redundancy_copies)
    else
      # Use specified buckets
      Storage.list_enabled_buckets()
      |> Enum.filter(&(&1.uuid in priority_buckets))
      |> Enum.take(redundancy_copies)
    end
  end

  # Whether `bucket` has the object. A bucket that raises (credentials, a
  # timeout) does not have it, for this request: the next bucket is tried
  # instead of the whole read failing. The recorded buckets are tried first
  # now, so a sick one must not take a file down that another copy serves.
  defp bucket_holds?(bucket, file_path) do
    get_provider_for_bucket(bucket).file_exists?(bucket, file_path)
  rescue
    error ->
      Logger.warning(
        "Storage: could not check #{file_path} on bucket #{bucket.name}: #{Exception.message(error)}"
      )

      false
  end

  defp forced_buckets(bucket_uuids) do
    enabled = Map.new(Storage.list_enabled_buckets(), &{to_string(&1.uuid), &1})

    bucket_uuids
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.flat_map(&List.wrap(Map.get(enabled, &1)))
  end

  defp select_buckets_for_retrieval(priority_buckets) do
    if Enum.empty?(priority_buckets) do
      # Use all enabled buckets ordered by priority (simple sort, no usage calculation needed for retrieval)
      get_enabled_buckets()
      |> Enum.sort_by(& &1.priority)
    else
      # Use specified buckets
      get_enabled_buckets()
      |> Enum.filter(&(&1.uuid in priority_buckets))
    end
  end

  # The buckets to read `file_path` from: `{located, fallback}`. With no
  # buckets named, the ones its location rows name come first and every
  # other enabled bucket is the fallback; each group keeps the retrieval
  # order (by priority). Named buckets are used as they are, with no
  # fallback.
  defp read_order(file_path, []) do
    case Locations.bucket_uuids(file_path) do
      # Checked and found in no bucket: not asked about again on every
      # request (the backfill remembered the miss).
      [] ->
        if Locations.known_missing?(file_path),
          do: {[], []},
          else: {[], select_buckets_for_retrieval([])}

      located ->
        Locations.located_first(select_buckets_for_retrieval([]), located)
    end
  end

  defp read_order(_file_path, priority_buckets),
    do: {select_buckets_for_retrieval(priority_buckets), []}

  defp store_across_buckets(source_path, buckets, opts) do
    # Use path_prefix if provided, otherwise generate a path
    destination_path =
      case Keyword.get(opts, :path_prefix) do
        nil -> generate_destination_path(source_path, opts)
        path_prefix -> path_prefix
      end

    results =
      buckets
      |> Enum.map(fn bucket ->
        provider = get_provider_for_bucket(bucket)
        result = provider.store_file(bucket, source_path, destination_path, opts)
        {bucket, result}
      end)

    # Only include buckets where the upload actually succeeded
    successful_buckets =
      Enum.filter(results, fn {_bucket, result} ->
        result == :ok or match?({:ok, _}, result)
      end)

    if successful_buckets != [] do
      file_info = %{
        destination_path: destination_path,
        stored_in: length(buckets),
        successful_storages: length(successful_buckets),
        bucket_ids: Enum.map(successful_buckets, fn {bucket, _} -> bucket.uuid end)
      }

      {:ok, file_info}
    else
      {:error, "Failed to store file in any bucket"}
    end
  end

  defp retrieve_with_failover(_file_path, [], _opts), do: {:error, "File not found in any bucket"}

  defp retrieve_with_failover(file_path, [bucket | remaining_buckets], opts) do
    provider = get_provider_for_bucket(bucket)

    destination_path =
      Keyword.get(opts, :destination_path, generate_temp_path() <> temp_extension(file_path))

    case safe_retrieve(provider, bucket, file_path, destination_path) do
      :ok ->
        {:ok, destination_path, bucket}

      {:error, reason} ->
        Logger.debug(
          "Storage: #{file_path} not read from bucket #{bucket.name}: #{inspect(reason)}"
        )

        retrieve_with_failover(file_path, remaining_buckets, opts)
    end
  end

  # A bucket that raises while reading fails over like one that errors.
  defp safe_retrieve(provider, bucket, file_path, destination_path) do
    provider.retrieve_file(bucket, file_path, destination_path)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp get_provider_for_bucket(bucket) do
    {:ok, provider_module} = ProviderRegistry.get_provider(bucket.provider)
    provider_module
  end

  defp generate_destination_path(source_path, opts) do
    original_name = Path.basename(source_path)
    extension = Path.extname(original_name)
    base_name = Path.rootname(original_name)

    timestamp = UtilsDate.utc_now() |> DateTime.to_iso8601()
    random_suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    prefix = Keyword.get(opts, :path_prefix, "")
    subdir = Keyword.get(opts, :subdir, timestamp)

    Path.join([prefix, subdir, "#{base_name}_#{random_suffix}#{extension}"])
  end

  defp generate_temp_path do
    temp_dir = System.tmp_dir!()
    random_name = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(temp_dir, "phoenix_kit_#{random_name}")
  end

  @doc false
  # The extension a processing temp copy of `file_path` should carry.
  #
  # ImageMagick identifies some formats (ICO among them) by extension alone,
  # so an extensionless copy fails with "no decode delegate". But the stored
  # extension is the uploader's filename, and an extension also *selects*
  # the coders that have no magic bytes to sniff — MVG, MSL, TXT — which an
  # extensionless copy never reaches. So it is kept only when it names a
  # media type (image, video, audio, PDF); `.mvg` uploaded as `image/png`
  # gets no extension and ImageMagick still reads it by content alone.
  @spec temp_extension(String.t()) :: String.t()
  def temp_extension(file_path) do
    case MIME.from_path(file_path) do
      "image/" <> _ -> Path.extname(file_path)
      "video/" <> _ -> Path.extname(file_path)
      "audio/" <> _ -> Path.extname(file_path)
      "application/pdf" -> Path.extname(file_path)
      _ -> ""
    end
  end

  @doc """
  Drops the cached list of enabled buckets, so the next read sees the
  database. Called whenever a bucket is created, updated or deleted. The
  cache only spares a query per file request; it expires on its own after
  five minutes, which is how long a bucket edit used to take to apply.
  """
  def invalidate_bucket_cache do
    :persistent_term.erase(:phoenix_kit_buckets_cache)
    :ok
  end

  defp get_enabled_buckets do
    # Cache bucket list to avoid querying on every file request
    cache_key = :phoenix_kit_buckets_cache
    current_time = System.monotonic_time(:millisecond)

    case :persistent_term.get(cache_key, nil) do
      {timestamp, buckets} when current_time - timestamp < @buckets_cache_ttl ->
        # Cache hit - return cached buckets
        buckets

      _ ->
        # Cache miss or expired - fetch fresh buckets
        buckets = Storage.list_enabled_buckets()
        :persistent_term.put(cache_key, {current_time, buckets})
        buckets
    end
  end

  defp get_redundancy_copies do
    Settings.get_setting_cached("storage_redundancy_copies", "1")
    |> String.to_integer()
    |> max(1)
    |> min(5)
  end

  defp get_auto_generate_variants do
    Settings.get_setting_cached("storage_auto_generate_variants", "true") == "true"
  end

  @doc """
  Returns the local filesystem path for a file if stored locally.

  This function checks enabled buckets with "local" provider and returns the
  direct path to the file if it exists. This allows serving files directly
  without copying to a temp file first.

  ## Returns

  - `{:ok, path}` - File exists at the local path
  - `{:error, :not_local}` - No local bucket contains the file
  """
  def get_local_file_path(file_path), do: local_path(file_path, read_order(file_path, []))

  defp local_path(file_path, {located, fallback}) do
    Enum.find_value(located, &local_hit(&1, file_path, false)) ||
      Enum.find_value(fallback, {:error, :not_local}, &local_hit(&1, file_path, true))
  end

  # `{:ok, path}` when `bucket` is local and holds `file_path`; a hit found
  # by probing (`record?`) is recorded as a location.
  defp local_hit(%{provider: "local"} = bucket, file_path, record?) do
    full_path = Path.join(Local.root(bucket), file_path)

    if File.exists?(full_path) do
      if record?, do: Locations.record(file_path, bucket.uuid)
      {:ok, full_path}
    end
  end

  defp local_hit(_bucket, _file_path, _record?), do: nil

  @doc """
  Returns file access info based on bucket access_type.

  Determines how a file should be served based on its storage location:
  - Local files are always served directly
  - Remote files depend on bucket's access_type setting

  ## Returns

  - `{:local, path}` - File is local, serve directly from filesystem
  - `{:redirect, url}` - Redirect to public URL (for public buckets)
  - `{:signed_redirect, url}` - Redirect to a short-lived signed URL (a
    public bucket, with `:download` given)
  - `{:proxy, file_name}` - Download and proxy through server (for private buckets)
  - `{:error, :not_found}` - File not found in any bucket

  ## Options

  - `:download` - response headers (`:disposition`, `:content_type`) for a
    file that must download rather than render. A public bucket's plain
    object URL answers with the object's stored headers, so for such a file
    a public bucket hands out a signed URL that overrides them
    (`c:PhoenixKit.Modules.Storage.Provider.signed_download_url/3`), or is
    proxied when its provider cannot sign one.
  """
  def get_file_access(file_name, opts \\ []) do
    order = read_order(file_name, [])

    case local_path(file_name, order) do
      {:ok, path} ->
        {:local, path}

      {:error, :not_local} ->
        get_remote_file_access(file_name, order, Keyword.get(opts, :download))
    end
  end

  defp get_remote_file_access(file_name, {located, fallback}, download) do
    Enum.find_value(located, &check_bucket_for_file(&1, file_name, download, false)) ||
      Enum.find_value(
        fallback,
        {:error, :not_found},
        &check_bucket_for_file(&1, file_name, download, true)
      )
  end

  defp check_bucket_for_file(%{provider: "local"}, _file_name, _download, _record?), do: nil

  defp check_bucket_for_file(bucket, file_name, download, record?) do
    provider = get_provider_for_bucket(bucket)

    if bucket_holds?(bucket, file_name) do
      if record?, do: Locations.record(file_name, bucket.uuid)
      bucket_access(bucket, file_name, provider, download)
    end
  end

  defp public_bucket?(%{access_type: type}) when type in ["private", "signed"], do: false
  defp public_bucket?(_bucket), do: true

  # How long a `"signed"` bucket's URL for one request lives.
  @signed_url_seconds 300

  @doc false
  # How a remote bucket that holds `file_name` serves it. Public and
  # `@doc false` only so the decision is testable without a live bucket.
  def bucket_access(%{access_type: "private"}, file_name, _provider, _download) do
    {:proxy, file_name}
  end

  # A `"signed"` bucket is served by a short-lived presigned URL made for
  # this request, never by its plain object URL; proxied when the provider
  # cannot sign. It used to fall through to the public redirect.
  def bucket_access(%{access_type: "signed"} = bucket, file_name, provider, download) do
    opts = Keyword.put(download || [], :expires_in, @signed_url_seconds)

    with true <- Code.ensure_loaded?(provider),
         true <- function_exported?(provider, :signed_download_url, 3),
         {:ok, url} <- provider.signed_download_url(bucket, file_name, opts) do
      {:signed_redirect, url}
    else
      _ -> {:proxy, file_name}
    end
  end

  # "public" or nil (default), for a file that must download.
  def bucket_access(bucket, file_name, provider, download) when is_list(download) do
    with true <- Code.ensure_loaded?(provider),
         true <- function_exported?(provider, :signed_download_url, 3),
         {:ok, url} <- provider.signed_download_url(bucket, file_name, download) do
      {:signed_redirect, url}
    else
      _ -> {:proxy, file_name}
    end
  end

  def bucket_access(bucket, file_name, provider, nil) do
    case provider.public_url(bucket, file_name) do
      nil -> nil
      url -> {:redirect, url}
    end
  end
end
